// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX adapter behavioral tests
/// @author DreamMargin contributors
/// @notice Verifies generation binding, immediate execution, and balance reconciliation.
/// @dev Tests use actual mock token movements rather than interface-selector assertions.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";

import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {DreamDexAdapterHarness} from "test/harness/DreamDexAdapterHarness.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Exercises the adapter against a complete local DreamDEX generation.
contract DreamDexAdapterTest is Test {
  bytes32 private constant _MARKET_ID = keccak256("adapter-market");
  uint256 private constant _YES_ID = 101;
  uint256 private constant _NO_ID = 102;
  uint256 private constant _ONE = 1e6;
  uint256 private constant _PRICE = 600_000;
  uint256 private constant _QUANTITY = 4 * _ONE;
  uint256 private constant _HALF_FILL = 5_000;
  uint256 private constant _TIMESTAMP = 1_000_000;
  uint256 private constant _DEADLINE = 1_001_000;
  uint64 private constant _EXPIRY = 1_100_000;
  uint64 private constant _EXPIRY_NS = _EXPIRY * 1e9;
  address private constant _SETTLEMENT = address(0x5151);

  MockERC20 private _collateral;
  MockERC6909 private _outcome;
  MockDreamDexBinaryMarket private _market;
  MockDreamDexBinaryPool private _pool;
  MockDreamDexBinaryModule private _module;
  DreamDexAdapterHarness private _adapter;
  MarketKey private _yesKey;

  /// @notice Creates one internally consistent, liquid DreamDEX generation.
  function setUp() external {
    vm.warp(_TIMESTAMP);
    _collateral = new MockERC20("Test USD", "tUSD", 6);
    _outcome = new MockERC6909();
    _market = new MockDreamDexBinaryMarket(
      address(_outcome), _YES_ID, _NO_ID, address(1), address(_collateral), _EXPIRY
    );
    IDreamDexBinaryPool.BinaryPoolInfo memory info = IDreamDexBinaryPool.BinaryPoolInfo({
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
      marketNonce: 1,
      finalized: false
    });
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(info, grid, _EXPIRY_NS);
    _market.setPool(address(_pool));

    _module = new MockDreamDexBinaryModule(_SETTLEMENT);
    _module.setMarket(
      _MARKET_ID,
      1,
      MockModuleMarket({
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
      })
    );
    _adapter = new DreamDexAdapterHarness(address(_module));
    _yesKey =
      MarketKey(_MARKET_ID, address(_pool), 1, address(_outcome), _YES_ID, address(_collateral));

    _collateral.mint(address(_adapter), 20 * _ONE);
    _collateral.mint(address(_pool), 100 * _ONE);
    _outcome.mint(address(_adapter), _YES_ID, 10 * _ONE);
    _outcome.mint(address(_adapter), _NO_ID, 10 * _ONE);
    _outcome.mint(address(_pool), _YES_ID, 100 * _ONE);
    _outcome.mint(address(_pool), _NO_ID, 100 * _ONE);
  }

  /// @notice Validates normalized YES and NO generation values from all three contracts.
  function test_validatesCompleteGenerationForBothOutcomes() external view {
    DreamDexAdapter.ValidatedGeneration memory yes = _adapter.validateGeneration(_yesKey, 0, true);
    assertEq(yes.market, address(_market));
    assertEq(yes.oppositeId, _NO_ID);
    assertEq(yes.oneCollateral, _ONE);
    assertEq(yes.orderBook.lotSize, _ONE);

    MarketKey memory noKey = _yesKey;
    noKey.outcomeId = _NO_ID;
    DreamDexAdapter.ValidatedGeneration memory no = _adapter.validateGeneration(noKey, 1, true);
    assertEq(no.oppositeId, _YES_ID);
  }

  /// @notice Rejects the old tuple immediately after the module nonce advances.
  function test_rejectsRecycledPoolGeneration() external {
    MockModuleMarket memory record = _moduleRecord();
    _module.setMarket(_MARKET_ID, 2, record);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.PoolRecycled.selector, address(_pool), uint64(1), uint64(2)
      )
    );
    // The call is expected to revert before returning normalized generation data.
    // forge-lint: disable-next-line(unused-return)
    _adapter.validateGeneration(_yesKey, 0, true);
  }

  /// @notice Rejects a locked market even when every generation field still matches.
  function test_rejectsNonTradingMarketForExecution() external {
    _market.setStatus(2);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidMarketStatus.selector, address(_market), uint8(2), uint8(1)
      )
    );
    // The call is expected to revert before returning an execution result.
    // forge-lint: disable-next-line(unused-return)
    _adapter.buyOutcome(_buyOrder(0));
  }

  /// @notice Reconciles a partial YES IOC buy from actual token balances and clears approval.
  function test_iocBuyUsesActualDeltasAndClearsApproval() external {
    _pool.setExecution(_HALF_FILL, 0);
    DreamDexAdapter.ExecutionResult memory result = _adapter.buyOutcome(_buyOrder(0));

    assertEq(result.outcomeAmount, 2 * _ONE);
    assertEq(result.collateralAmount, 1_200_000);
    assertEq(_collateral.allowance(address(_adapter), address(_pool)), 0);
    assertEq(_pool.lastKind(), 0);
    assertEq(_pool.lastOrderType(), 2);
  }

  /// @notice Applies the YES-price complement when buying the NO outcome.
  function test_noBuyUsesYesPriceConvention() external {
    _pool.setExecution(_HALF_FILL, 0);
    DreamDexAdapter.ExecutionResult memory result = _adapter.buyOutcome(_buyOrder(1));
    assertEq(result.outcomeAmount, 2 * _ONE);
    assertEq(result.collateralAmount, 800_000);
    assertEq(_pool.lastKind(), 2);
  }

  /// @notice Reconciles a partial sale and removes the residual exact-ID allowance.
  function test_iocSellUsesActualDeltasAndClearsExactAllowance() external {
    _pool.setExecution(_HALF_FILL, 0);
    DreamDexAdapter.ImmediateOrder memory order = _buyOrder(0);
    order.minimumOutput = 1_200_000;
    DreamDexAdapter.ExecutionResult memory result = _adapter.sellOutcome(order);

    assertEq(result.outcomeAmount, 2 * _ONE);
    assertEq(result.collateralAmount, 1_200_000);
    assertEq(_outcome.allowance(address(_adapter), address(_pool), _YES_ID), 0);
    assertEq(_pool.lastKind(), 1);
  }

  /// @notice Rejects a partial FOK response without retaining any token movement.
  function test_fokFailureIsAtomic() external {
    _pool.setExecution(_HALF_FILL, 0);
    DreamDexAdapter.ImmediateOrder memory order = _buyOrder(0);
    order.orderType = 1;
    uint256 collateralBefore = _collateral.balanceOf(address(_adapter));
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.OrderRejected.selector, address(_pool), uint8(1))
    );
    // The call is expected to revert before returning an execution result.
    // forge-lint: disable-next-line(unused-return)
    _adapter.buyOutcome(order);
    assertEq(_collateral.balanceOf(address(_adapter)), collateralBefore);
  }

  /// @notice Rejects a nonzero immediate-order ID and rolls the venue transfer back.
  function test_rejectsRestingOrderIdAtomically() external {
    _pool.setExecution(10_000, 77);
    uint256 outcomeBefore = _outcome.balanceOf(address(_adapter), _YES_ID);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.RestingOrder.selector, uint128(77)));
    // The call is expected to revert before returning an execution result.
    // forge-lint: disable-next-line(unused-return)
    _adapter.buyOutcome(_buyOrder(0));
    assertEq(_outcome.balanceOf(address(_adapter), _YES_ID), outcomeBefore);
  }

  /// @notice Rejects non-immediate order types before granting any venue allowance.
  function test_rejectsRestingOrderTypeBeforeInteraction() external {
    DreamDexAdapter.ImmediateOrder memory order = _buyOrder(0);
    order.orderType = 0;
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.UnsupportedOrderType.selector, uint8(0))
    );
    // The call is expected to revert before returning an execution result.
    // forge-lint: disable-next-line(unused-return)
    _adapter.buyOutcome(order);
    assertEq(_collateral.allowance(address(_adapter), address(_pool)), 0);
  }

  /// @notice Returns a standard IOC buy request for either outcome.
  function _buyOrder(uint8 outcomeIndex)
    private
    view
    returns (DreamDexAdapter.ImmediateOrder memory order)
  {
    MarketKey memory key = _yesKey;
    if (outcomeIndex == 1) key.outcomeId = _NO_ID;
    order = DreamDexAdapter.ImmediateOrder({
      key: key,
      outcomeIndex: outcomeIndex,
      price: _PRICE,
      quantity: _QUANTITY,
      minimumOutput: 2 * _ONE,
      maximumInput: 3 * _ONE,
      deadline: _DEADLINE,
      orderType: 2,
      userData: 99
    });
  }

  /// @notice Reads the current module fixture so tests can mutate only the nonce.
  /// @return record Full module market fixture.
  function _moduleRecord() private view returns (MockModuleMarket memory record) {
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
}
