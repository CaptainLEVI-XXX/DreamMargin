// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX mark-oracle tests
/// @author DreamMargin contributors
/// @notice Verifies generation binding, bounded depth, maturity, staleness, and ring behavior.
/// @dev Named observation parameters are conservative test fixtures, not production settings.

import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";

import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";

// Expected-revert calls intentionally ignore return values and fixed-width casts construct fixtures.
// forge-lint: disable-start(calls-loop, unsafe-typecast, unused-return)

/// @notice Exercises YES and NO observations against one mutable local DreamDEX generation.
contract DreamDexMarkOracleTest is Test {
  /// @notice One whole collateral and outcome token.
  uint256 private constant _ONE = 1e6;

  /// @notice Deterministic first observation timestamp.
  uint256 private constant _START = 1_000_000;

  /// @notice Market expiry safely after all ordinary test observations.
  uint64 private constant _EXPIRY = 1_100_000;

  /// @notice Test generation market identifier.
  bytes32 private constant _MARKET_ID = keccak256("oracle-market");

  /// @notice YES outcome identifier.
  uint256 private constant _YES_ID = 11;

  /// @notice NO outcome identifier.
  uint256 private constant _NO_ID = 12;

  /// @notice Permanent mock settlement binding.
  address private constant _SETTLEMENT = address(0x5151);

  /// @notice Unauthorized policy caller.
  address private constant _STRANGER = address(0xBAD);

  MockERC20 private _collateral;
  MockERC6909 private _outcome;
  MockDreamDexBinaryMarket private _market;
  MockDreamDexBinaryPool private _pool;
  MockDreamDexBinaryModule private _module;
  DreamDexMarkOracle private _oracle;
  MarketKey private _yesKey;
  bytes32 private _yesGenerationKey;

  /// @notice Creates one valid liquid generation and its immutable oracle policy.
  function setUp() external {
    vm.warp(_START);
    _collateral = new MockERC20("Oracle USD", "oUSD", 6);
    _outcome = new MockERC6909();
    _market = new MockDreamDexBinaryMarket(
      address(_outcome), _YES_ID, _NO_ID, address(1), address(_collateral), _EXPIRY
    );
    IDreamDexBinaryPool.BinaryPoolInfo memory info = _poolInfo(1);
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(info, grid, _EXPIRY * 1e9);
    _market.setPool(address(_pool));
    _module = new MockDreamDexBinaryModule(_SETTLEMENT);
    _module.setMarket(_MARKET_ID, 1, _moduleMarket());
    _oracle = new DreamDexMarkOracle(address(_module), address(this));
    _yesKey =
      MarketKey(_MARKET_ID, address(_pool), 1, address(_outcome), _YES_ID, address(_collateral));
    _yesGenerationKey = _generationKey(_yesKey);
    _setHealthyBook();
    _oracle.configureGeneration(_yesGenerationKey, _config(_yesKey, 3));
  }

  /// @notice Records a complete depth-weighted YES observation in native collateral units.
  function test_observeYesUsesBoundedExecutableDepth() external {
    MarkObservation memory observation = _oracle.observe(_yesGenerationKey);

    assertEq(observation.timestamp, _START);
    assertEq(observation.poolNonce, 1);
    assertEq(observation.marketStatus, 1);
    assertEq(observation.bestBid, 600_000);
    assertEq(observation.sameSideDepthBid, 566_666);
    assertEq(observation.oppositeSideDepthAsk, 433_334);
    assertEq(observation.conservativeMark, 566_666);
    assertEq(observation.cumulativeMarkSeconds, 0);
  }

  /// @notice Converts the YES ask side into NO bids and opposite YES asks.
  function test_observeNoUsesComplementPrices() external {
    MarketKey memory noKey = _yesKey;
    noKey.outcomeId = _NO_ID;
    bytes32 noGenerationKey = _generationKey(noKey);
    _oracle.configureGeneration(noGenerationKey, _config(noKey, 3));

    MarkObservation memory observation = _oracle.observe(noGenerationKey);
    assertEq(observation.bestBid, 350_000);
    assertEq(observation.sameSideDepthBid, 333_333);
    assertEq(observation.oppositeSideDepthAsk, 666_667);
    assertEq(observation.conservativeMark, 333_333);
  }

  /// @notice Accumulates the prior mark over time so the newest sample has zero instant weight.
  function test_newestTransientBidCannotImmediatelyChangeMatureTwap() external {
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 60);
    _setHighBook();
    _oracle.observe(_yesGenerationKey);

    (uint256 mark, uint256 age, uint256 updatedAt) = _oracle.conservativeTwap(_yesGenerationKey);
    assertEq(mark, 566_666);
    assertEq(age, 60);
    assertEq(updatedAt, _START + 60);
  }

  /// @notice Uses the next elapsed interval to incorporate an accepted mark into TWAP.
  function test_twapIncorporatesObservationOnlyAfterTimePasses() external {
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 60);
    _setHighBook();
    MarkObservation memory second = _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 120);
    MarkObservation memory third = _oracle.observe(_yesGenerationKey);

    assertEq(second.conservativeMark, 766_666);
    assertEq(third.cumulativeMarkSeconds - second.cumulativeMarkSeconds, 766_666 * 60);
    (uint256 mark,,) = _oracle.conservativeTwap(_yesGenerationKey);
    assertEq(mark, 766_666);
  }

  /// @notice Caps an accumulated high mark when its transient supporting bids disappear.
  function test_cancelledTransientBidIsCappedByCurrentRecovery() external {
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 60);
    _setHighBook();
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 120);
    _setHealthyBook();
    _oracle.observe(_yesGenerationKey);

    (uint256 mark,,) = _oracle.conservativeTwap(_yesGenerationKey);
    assertEq(mark, 566_666);
  }

  /// @notice Rejects same-block and otherwise under-spaced observations.
  function test_updateSpacingRejectsSameBlock() external {
    _oracle.observe(_yesGenerationKey);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ObservationTooSoon.selector, 0, 30));
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Fails closed until two observations span the configured mature age.
  function test_twapRequiresMatureWindow() external {
    _oracle.observe(_yesGenerationKey);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.OracleNotReady.selector, _yesGenerationKey, 0, 60)
    );
    _oracle.conservativeTwap(_yesGenerationKey);

    vm.warp(_START + 30);
    _oracle.observe(_yesGenerationKey);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.OracleNotReady.selector, _yesGenerationKey, 30, 60
      )
    );
    _oracle.conservativeTwap(_yesGenerationKey);
  }

  /// @notice Rejects a mature window whose newest observation exceeds maximum age.
  function test_staleNewestObservationFailsClosed() external {
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 60);
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 181);

    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.StaleOracle.selector, _yesGenerationKey, 121, 120)
    );
    _oracle.conservativeTwap(_yesGenerationKey);
  }

  /// @notice Wraps at configured capacity while retaining correct oldest and newest timestamps.
  function test_ringWraparoundRetainsBoundedHistory() external {
    for (uint256 i = 0; i < 5; ++i) {
      if (i != 0) vm.warp(_START + i * 30);
      _oracle.observe(_yesGenerationKey);
    }

    (, ObservationRing memory ring) = _oracle.generationState(_yesGenerationKey);
    assertEq(ring.cardinality, 3);
    assertEq(ring.nextIndex, 2);
    assertEq(ring.oldestTimestamp, _START + 60);
    assertEq(ring.newestTimestamp, _START + 120);
    assertEq(_oracle.observationAt(_yesGenerationKey, 2).timestamp, _START + 60);
  }

  /// @notice Rejects empty or insufficient relevant depth instead of admitting a zero mark.
  function test_insufficientDepthFailsClosed() external {
    IDreamDexBinaryPool.BookLevel[] memory oneLevel = new IDreamDexBinaryPool.BookLevel[](1);
    oneLevel[0] = IDreamDexBinaryPool.BookLevel({price: 600_000, quantity: _ONE});
    _pool.setBookLevels(true, oneLevel);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InsufficientBookDepth.selector, _yesGenerationKey, _ONE, 3 * _ONE
      )
    );
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Rejects a crossed book before sampling either recovery route.
  function test_crossedBookFailsClosed() external {
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 550_000, quantity: 4 * _ONE});
    _pool.setBookLevels(false, asks);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidBook.selector, address(_pool), 600_000, 550_000
      )
    );
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Revalidates pool generation on every update after recycling.
  function test_recycledPoolCannotExtendOldGenerationHistory() external {
    _oracle.observe(_yesGenerationKey);
    _pool.recycle(_poolInfo(2), _EXPIRY * 1e9);

    vm.warp(_START + 30);
    vm.expectRevert();
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Revalidates authoritative market status on updates and reads.
  function test_nonTradingStatusBlocksUpdateAndRead() external {
    _oracle.observe(_yesGenerationKey);
    vm.warp(_START + 60);
    _oracle.observe(_yesGenerationKey);
    _market.setStatus(2);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidMarketStatus.selector, address(_market), uint8(2), uint8(1)
      )
    );
    _oracle.conservativeTwap(_yesGenerationKey);
  }

  /// @notice Rejects risk-increasing observation reads at market expiry.
  function test_expiryBlocksObservation() external {
    vm.warp(_EXPIRY);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.MarketExpired.selector, _EXPIRY, _EXPIRY)
    );
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Restricts immutable configuration and permanent disablement to configurator.
  function test_configurationAuthorityAndImmutability() external {
    vm.prank(_STRANGER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.NotConfigurator.selector, _STRANGER, address(this)
      )
    );
    _oracle.disableGeneration(_yesGenerationKey);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.GenerationAlreadyConfigured.selector, _yesGenerationKey
      )
    );
    _oracle.configureGeneration(_yesGenerationKey, _config(_yesKey, 3));
    _oracle.disableGeneration(_yesGenerationKey);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.UnsupportedGeneration.selector, _yesGenerationKey)
    );
    _oracle.observe(_yesGenerationKey);
  }

  /// @notice Rejects a generation key that does not bind the complete configured tuple.
  function test_configurationRejectsMismatchedGenerationKey() external {
    MarketKey memory noKey = _yesKey;
    noKey.outcomeId = _NO_ID;
    bytes32 correct = _generationKey(noKey);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.GenerationMismatch.selector, keccak256("wrong"), correct
      )
    );
    _oracle.configureGeneration(keccak256("wrong"), _config(noKey, 3));
  }

  /// @notice Returns the standard immutable observation policy fixture.
  /// @param key Exact generation tuple.
  /// @param capacity Circular ring capacity.
  /// @return config Complete enabled policy.
  function _config(MarketKey memory key, uint16 capacity)
    private
    pure
    returns (OracleConfig memory config)
  {
    config = OracleConfig({
      key: key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: uint128(3 * _ONE),
      maxObservations: capacity,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Replaces both sides with the baseline ordered, uncrossed book.
  function _setHealthyBook() private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](2);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: 600_000, quantity: 2 * _ONE});
    bids[1] = IDreamDexBinaryPool.BookLevel({price: 500_000, quantity: 2 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](2);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 650_000, quantity: 2 * _ONE});
    asks[1] = IDreamDexBinaryPool.BookLevel({price: 700_000, quantity: 2 * _ONE});
    _pool.setBookLevels(true, bids);
    _pool.setBookLevels(false, asks);
  }

  /// @notice Replaces both sides with a high but still uncrossed transient book.
  function _setHighBook() private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](2);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: 800_000, quantity: 2 * _ONE});
    bids[1] = IDreamDexBinaryPool.BookLevel({price: 700_000, quantity: 2 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 850_000, quantity: 4 * _ONE});
    _pool.setBookLevels(true, bids);
    _pool.setBookLevels(false, asks);
  }

  /// @notice Returns the module's complete generation record for the current pool.
  /// @return record Complete module record.
  function _moduleMarket() private view returns (MockModuleMarket memory record) {
    record = MockModuleMarket({
      oracleQuestionId: 7,
      outcomeSlotCount: 2,
      voidPolicy: 0,
      collateral: address(_collateral),
      originOperatorId: 0,
      originVenueId: bytes32(0),
      oracleAdapter: address(0xA11),
      creator: address(0xC0DE),
      market: address(_market),
      pool: address(_pool),
      yesId: _YES_ID,
      noId: _NO_ID,
      tradingStart: 900_000,
      expiry: _EXPIRY
    });
  }

  /// @notice Returns a pool binding with a selected recyclable generation nonce.
  /// @param nonce Pool generation nonce.
  /// @return info Complete pool binding.
  function _poolInfo(uint64 nonce)
    private
    view
    returns (IDreamDexBinaryPool.BinaryPoolInfo memory info)
  {
    info = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(_collateral),
      market: address(_market),
      outcomeToken: address(_outcome),
      yesId: _YES_ID,
      noId: _NO_ID,
      oneCollateral: _ONE,
      setBacking: _ONE,
      feeRecipient: address(0xFEE),
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: _SETTLEMENT,
      marketNonce: nonce,
      finalized: false
    });
  }

  /// @notice Derives the canonical generation key used by production storage.
  /// @param key Complete generation tuple.
  /// @return generationKey Hash of every tuple field.
  function _generationKey(MarketKey memory key) private pure returns (bytes32 generationKey) {
    generationKey = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
  }
}

// forge-lint: disable-end(calls-loop, unsafe-typecast, unused-return)
