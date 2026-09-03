// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position-opening tests
/// @author DreamMargin contributors
/// @notice Verifies atomic borrowing, immediate execution, reconciliation, and collateral custody.
/// @dev Each test uses complete vault, oracle, controller, and DreamDEX integration models.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {PositionSettlement} from "src/dreammargin/base/PositionSettlement.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  MarketKey,
  Position,
  PositionStatus,
  ProtocolMode,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {DreamMarginControllerHarness} from "test/harness/DreamMarginControllerHarness.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";

// Expected-revert lifecycle calls intentionally ignore returned values.
// forge-lint: disable-start(unused-return)

/// @notice Exercises leveraged opening and exact-ID collateral additions end to end.
contract PositionOpenTest is Test {
  uint256 private constant _ONE = 1e6;
  uint128 private constant _DEPTH_QUANTITY = 100_000_000;
  uint256 private constant _START = 1_000_000;
  uint64 private constant _EXPIRY = 2_000_000;
  uint40 private constant _DELAY = 1 days;
  bytes32 private constant _MARKET_ID = keccak256("position-open-market");
  bytes32 private constant _MARKET_GROUP = keccak256("position-open-group");
  uint256 private constant _YES_ID = 71;
  uint256 private constant _NO_ID = 72;
  address private constant _SETTLEMENT = address(0x5151);
  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _LP = address(0x2001);
  address private constant _OWNER = address(0x2002);
  address private constant _STRANGER = address(0xBAD);

  MockERC20 private _collateral;
  MockERC6909 private _outcome;
  MockDreamDexBinaryMarket private _market;
  MockDreamDexBinaryPool private _pool;
  MockDreamDexBinaryModule private _module;
  DreamMarginVault private _vault;
  DreamDexMarkOracle private _oracle;
  PositionOpen private _positionOpen;
  PositionClose private _positionClose;
  PositionLiquidation private _positionLiquidation;
  PositionSettlement private _positionSettlement;
  DreamMarginControllerHarness private _controller;
  MarketKey private _yesKey;
  MarketKey private _noKey;
  bytes32 private _yesGeneration;
  bytes32 private _noGeneration;

  /// @notice Deploys, funds, registers, and matures both outcomes of one market.
  function setUp() external {
    vm.warp(_START);
    _collateral = new MockERC20("Margin USD", "mUSD", 6);
    _outcome = new MockERC6909();
    _market = new MockDreamDexBinaryMarket(
      address(_outcome), _YES_ID, _NO_ID, address(1), address(_collateral), _EXPIRY
    );
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(_poolInfo(), grid, _EXPIRY * 1e9);
    _market.setPool(address(_pool));
    _module = new MockDreamDexBinaryModule(_SETTLEMENT);
    _module.setMarket(_MARKET_ID, 1, _moduleMarket());
    _setBook();
    _positionOpen = new PositionOpen();
    _positionClose = new PositionClose();
    _positionLiquidation = new PositionLiquidation();
    _positionSettlement = new PositionSettlement();

    uint256 nextNonce = vm.getNonce(address(this));
    address predictedController = vm.computeCreateAddress(address(this), nextNonce + 2);
    _vault = new DreamMarginVault(address(_collateral), predictedController, 0);
    _oracle = new DreamDexMarkOracle(address(_module), predictedController);
    _controller = new DreamMarginControllerHarness(
      address(_module),
      address(_vault),
      address(_oracle),
      _FEE_RECIPIENT,
      address(_positionOpen),
      address(_positionClose),
      address(_positionLiquidation),
      address(_positionSettlement),
      _initialRoles(),
      _globalRisk()
    );
    assertEq(address(_controller), predictedController);

    _yesKey =
      MarketKey(_MARKET_ID, address(_pool), 1, address(_outcome), _YES_ID, address(_collateral));
    _noKey =
      MarketKey(_MARKET_ID, address(_pool), 1, address(_outcome), _NO_ID, address(_collateral));
    _yesGeneration = _deriveKey(_yesKey);
    _noGeneration = _deriveKey(_noKey);

    _fundIntegrationsAndOwners();
    _register(_yesGeneration, _generation(_yesKey, 0), _oraclePolicy(_yesKey));
    _register(_noGeneration, _generation(_noKey, 1), _oraclePolicy(_noKey));
    vm.warp(_START + _DELAY);
    _executeRegistration(
      _yesGeneration, _generation(_yesKey, 0), _oraclePolicy(_yesKey), keccak256("register-yes")
    );
    _executeRegistration(
      _noGeneration, _generation(_noKey, 1), _oraclePolicy(_noKey), keccak256("register-no")
    );
    _oracle.observe(_yesGeneration);
    _oracle.observe(_noGeneration);
    vm.warp(block.timestamp + 60);
    _oracle.observe(_yesGeneration);
    _oracle.observe(_noGeneration);
    vm.startPrank(_OWNER);
    _outcome.approve(address(_controller), _YES_ID, type(uint256).max);
    _outcome.approve(address(_controller), _NO_ID, type(uint256).max);
    vm.stopPrank();
  }

  /// @notice Records only actual YES balances and debt while preserving aggregate custody equality.
  function test_openYesPersistsReconciledPositionAndAggregates() external {
    (uint256 positionId, uint256 sharesBought, uint256 debtAssets) = _open(_yesParams());
    Position memory position = _controller.getPosition(positionId);

    assertEq(positionId, 1);
    assertEq(position.owner, _OWNER);
    assertEq(position.shares, 40 * _ONE);
    assertEq(position.debtShares, 10 * _ONE);
    assertEq(position.initialEquity, 10 * _ONE);
    assertEq(uint8(position.status), uint8(PositionStatus.ACTIVE));
    assertEq(sharesBought, 20 * _ONE);
    assertEq(debtAssets, 10 * _ONE);
    assertEq(_vault.performingDebt(), 10 * _ONE);
    assertEq(_collateral.balanceOf(address(_controller)), 0);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 40 * _ONE);
    (uint256 attributed, uint256 outcomeDebt, uint256 marketDebt, uint256 totalDebt) =
      _controller.aggregateState(_yesGeneration, _MARKET_GROUP, address(_outcome), _YES_ID);
    assertEq(attributed, 40 * _ONE);
    assertEq(outcomeDebt, position.debtShares);
    assertEq(marketDebt, position.debtShares);
    assertEq(totalDebt, position.debtShares);
    assertEq(_vault.totalDebtShares(), totalDebt);
  }

  /// @notice Pins the opening facet and prevents direct calls outside initialized controller state.
  function test_openingFacetIsImmutableAndOnlyUsableThroughController() external {
    assertEq(_controller.positionOpenFacet(), address(_positionOpen));
    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.UnsupportedGeneration.selector);
    _positionOpen.openPosition(_yesParams());
  }

  /// @notice Complements the YES limit price when borrowing to buy NO shares.
  function test_openNoUsesComplementPriceAndExactOutcomeId() external {
    IDreamMarginController.OpenParams memory params = _noParams();
    (uint256 positionId, uint256 sharesBought, uint256 debtAssets) = _open(params);
    Position memory position = _controller.getPosition(positionId);

    assertEq(_pool.lastKind(), LibDreamMarginConstants.ORDER_KIND_BUY_NO);
    assertEq(sharesBought, 25 * _ONE);
    assertEq(debtAssets, 10 * _ONE);
    assertEq(position.shares, 50 * _ONE);
    assertEq(position.outcomeId, _NO_ID);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
    assertEq(_outcome.balanceOf(address(_controller), _NO_ID), 50 * _ONE);
  }

  /// @notice Retires the unused half of an IOC borrow and records only the partial fill.
  function test_partialIocReturnsUnusedBorrowBeforeRecording() external {
    _pool.setExecution(5_000, 0);
    IDreamMarginController.OpenParams memory params = _yesParams();
    params.minSharesOut = 10 * _ONE;
    (uint256 positionId, uint256 sharesBought, uint256 debtAssets) = _open(params);
    Position memory position = _controller.getPosition(positionId);

    assertEq(sharesBought, 10 * _ONE);
    assertEq(position.shares, 30 * _ONE);
    assertEq(debtAssets, 5 * _ONE);
    assertEq(position.debtShares, 5 * _ONE);
    assertEq(_vault.performingDebt(), 5 * _ONE);
    assertEq(_vault.protocolReserve(), 0);
    assertEq(_collateral.balanceOf(address(_controller)), 0);
  }

  /// @notice Rolls back initial collateral and borrowing when a FOK order cannot fill completely.
  function test_failedFokLeavesNoPositionDebtOrCustody() external {
    _pool.setExecution(5_000, 0);
    IDreamMarginController.OpenParams memory params = _yesParams();
    params.orderType = LibDreamMarginConstants.ORDER_TYPE_FOK;
    uint256 ownerShares = _outcome.balanceOf(_OWNER, _YES_ID);
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.OrderRejected.selector,
        address(_pool),
        LibDreamMarginConstants.ORDER_TYPE_FOK
      )
    );
    _controller.openPosition(params);

    assertEq(_outcome.balanceOf(_OWNER, _YES_ID), ownerShares);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
    assertEq(_vault.performingDebt(), 0);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.PositionNotFound.selector, 1));
    _controller.getPosition(1);
  }

  /// @notice Requires an exact-ID allowance even when the owner grants global operator authority.
  function test_globalOperatorDoesNotReplaceExactIdAllowance() external {
    vm.startPrank(_OWNER);
    _outcome.approve(address(_controller), _YES_ID, 0);
    _outcome.setOperator(address(_controller), true);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InsufficientOutcomeAllowance.selector,
        address(_outcome),
        _YES_ID,
        0,
        20 * _ONE
      )
    );
    _controller.openPosition(_yesParams());
    vm.stopPrank();
  }

  /// @notice Blocks new borrowing in emergency modes while allowing owner collateral additions.
  function test_pausedModeBlocksOpenButAllowsCollateralAddition() external {
    (uint256 positionId,,) = _open(_yesParams());
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);

    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.ActionBlocked.selector,
        uint8(ProtocolMode.PAUSED),
        _controller.openPosition.selector
      )
    );
    _controller.openPosition(_yesParams());
    vm.prank(_OWNER);
    _controller.addCollateral(positionId, 3 * _ONE);
    assertEq(_controller.getPosition(positionId).shares, 43 * _ONE);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 43 * _ONE);
  }

  /// @notice Rejects collateral additions by any account other than the recorded owner.
  function test_addCollateralRequiresOwnerAndUpdatesExactAggregate() external {
    (uint256 positionId,,) = _open(_yesParams());
    _outcome.mint(_STRANGER, _YES_ID, 2 * _ONE);
    vm.prank(_STRANGER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.NotPositionOwner.selector, _STRANGER, _OWNER, positionId
      )
    );
    _controller.addCollateral(positionId, 2 * _ONE);

    vm.prank(_OWNER);
    _controller.addCollateral(positionId, 2 * _ONE);
    (uint256 attributed,,,) =
      _controller.aggregateState(_yesGeneration, _MARKET_GROUP, address(_outcome), _YES_ID);
    assertEq(attributed, 42 * _ONE);
    assertEq(attributed, _outcome.balanceOf(address(_controller), _YES_ID));
  }

  /// @notice Fails closed when the oracle's newest observation exceeds its freshness bound.
  function test_staleOraclePreventsAnyBorrowOrCollateralMovement() external {
    vm.warp(block.timestamp + 121);
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.StaleOracle.selector, _yesGeneration, 121, 120)
    );
    _controller.openPosition(_yesParams());
    assertEq(_vault.performingDebt(), 0);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
  }

  /// @notice Rejects a generation frozen by the guardian before touching owner balances.
  function test_frozenGenerationPreventsOpening() external {
    vm.prank(_GUARDIAN);
    _controller.freezeGeneration(_yesGeneration);
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.GenerationFrozen.selector, _yesGeneration)
    );
    _controller.openPosition(_yesParams());
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
  }

  /// @notice Rejects the pinned tuple after its recyclable module nonce advances.
  function test_recycledPoolPreventsOpening() external {
    _module.setMarket(_MARKET_ID, 2, _moduleMarket());
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.PoolRecycled.selector, address(_pool), uint64(1), uint64(2)
      )
    );
    _controller.openPosition(_yesParams());
  }

  /// @notice Rejects positions larger than their configured share of observed executable depth.
  function test_postFillDepthBoundRollsBackTradeAndDebt() external {
    IDreamMarginController.OpenParams memory params = _yesParams();
    params.initialShares = 41 * _ONE;
    params.leverageBps = 12_500;
    params.maxCollateralIn = 5_125_000;
    params.minSharesOut = 10 * _ONE;
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.PositionDepthExceeded.selector, 51 * _ONE, 50 * _ONE
      )
    );
    _controller.openPosition(params);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
  }

  /// @notice Reduces borrowing so a spread-paying fill remains within requested leverage.
  function test_spreadAdjustedDebtPreservesRequestedLeverage() external {
    IDreamMarginController.OpenParams memory params = _yesParams();
    params.limitPrice = 600_000;
    params.minSharesOut = 14 * _ONE;
    (uint256 positionId, uint256 sharesBought, uint256 debtAssets) = _open(params);
    assertEq(positionId, 1);
    assertEq(sharesBought, 14 * _ONE);
    assertEq(debtAssets, 8_400_000);
  }

  /// @notice Rejects nominal borrowing above the generation's per-position debt ceiling.
  function test_positionDebtCapRejectsRiskBeforeExternalMovement() external {
    IDreamMarginController.OpenParams memory params = _yesParams();
    params.leverageBps = 21_000;
    params.maxCollateralIn = 11 * _ONE;
    bytes32 scope = "POSITION_DEBT";
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.DebtCapExceeded.selector, scope, 11 * _ONE, 10 * _ONE
      )
    );
    _controller.openPosition(params);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), 0);
  }

  /// @notice Stops new debt at the configured pre-expiry opening cutoff.
  function test_openingCutoffStopsNewRiskBeforeTradingExpiry() external {
    vm.warp(_EXPIRY - 1_200);
    vm.prank(_OWNER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.OpeningCutoffReached.selector, _EXPIRY, _EXPIRY - 1_200, 1_200
      )
    );
    _controller.openPosition(_yesParams());
  }

  /// @notice Opens one position as its owner.
  /// @param params Complete opening request.
  /// @return positionId Newly allocated ID.
  /// @return sharesBought Actual shares bought.
  /// @return debtAssets Final debt assets.
  function _open(IDreamMarginController.OpenParams memory params)
    private
    returns (uint256 positionId, uint256 sharesBought, uint256 debtAssets)
  {
    vm.prank(_OWNER);
    (positionId, sharesBought, debtAssets) = _controller.openPosition(params);
  }

  /// @notice Returns the standard exactly 2x YES opening.
  /// @return params Bound YES opening parameters.
  function _yesParams() private view returns (IDreamMarginController.OpenParams memory params) {
    params = IDreamMarginController.OpenParams({
      key: _yesKey,
      outcomeIndex: 0,
      initialShares: 20 * _ONE,
      leverageBps: 20_000,
      maxCollateralIn: 10 * _ONE,
      minSharesOut: 20 * _ONE,
      limitPrice: 500_000,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600
    });
  }

  /// @notice Returns the standard exactly 2x NO opening.
  /// @return params Bound NO opening parameters using a YES-side limit.
  function _noParams() private view returns (IDreamMarginController.OpenParams memory params) {
    params = IDreamMarginController.OpenParams({
      key: _noKey,
      outcomeIndex: 1,
      initialShares: 25 * _ONE,
      leverageBps: 20_000,
      maxCollateralIn: 10 * _ONE,
      minSharesOut: 25 * _ONE,
      limitPrice: 600_000,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600
    });
  }

  /// @notice Funds vault cash, owner collateral, and pool execution inventory.
  function _fundIntegrationsAndOwners() private {
    _collateral.mint(_LP, 1_000 * _ONE);
    vm.startPrank(_LP);
    _collateral.approve(address(_vault), type(uint256).max);
    _vault.deposit(1_000 * _ONE, _LP);
    vm.stopPrank();
    _outcome.mint(_OWNER, _YES_ID, 100 * _ONE);
    _outcome.mint(_OWNER, _NO_ID, 100 * _ONE);
    _outcome.mint(address(_pool), _YES_ID, 500 * _ONE);
    _outcome.mint(address(_pool), _NO_ID, 500 * _ONE);
  }

  /// @notice Schedules one generation registration before the shared delay elapses.
  /// @param generationKey Full generation identifier.
  /// @param config Controller policy.
  /// @param oracleConfig Oracle observation policy.
  function _register(
    bytes32 generationKey,
    GenerationConfig memory config,
    OracleConfig memory oracleConfig
  ) private {
    bytes32 changeId = config.risk.outcomeIndex == 0
      ? keccak256("register-yes")
      : keccak256("register-no");
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(changeId, generationKey, config, oracleConfig);
  }

  /// @notice Executes one already-mature generation registration.
  /// @param generationKey Full generation identifier.
  /// @param config Controller policy.
  /// @param oracleConfig Oracle observation policy.
  /// @param changeId Previously scheduled identifier.
  function _executeRegistration(
    bytes32 generationKey,
    GenerationConfig memory config,
    OracleConfig memory oracleConfig,
    bytes32 changeId
  ) private {
    _controller.executeGenerationChange(changeId, generationKey, config, oracleConfig);
  }

  /// @notice Returns separated administrative accounts.
  /// @return roles Initial role assignment.
  function _initialRoles() private pure returns (DreamMarginController.InitialRoles memory roles) {
    roles = DreamMarginController.InitialRoles({
      governance: _GOVERNANCE,
      riskSteward: _RISK_STEWARD,
      guardian: _GUARDIAN,
      feeCollector: _FEE_COLLECTOR
    });
  }

  /// @notice Returns global admission and governance bounds.
  /// @return config Global risk policy.
  function _globalRisk() private pure returns (GlobalRiskConfig memory config) {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * _ONE,
      maxDailyRealizedLoss: 100 * _ONE,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: _DELAY,
      lossWindow: 1 days,
      lossCooldown: 2 days
    });
  }

  /// @notice Returns a bounded risk policy for one exact outcome.
  /// @param key Full generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @return config Controller generation record.
  function _generation(MarketKey memory key, uint8 outcomeIndex)
    private
    pure
    returns (GenerationConfig memory config)
  {
    config = GenerationConfig({
      key: key,
      risk: RiskConfig({
        maxDebtPerPosition: 10 * _ONE,
        maxDebtPerOutcome: 300 * _ONE,
        maxDebtPerMarket: 700 * _ONE,
        minDebt: _ONE,
        initialLtvBps: 6_000,
        maintenanceLtvBps: 7_500,
        collateralFactorBps: 8_000,
        liquidationBonusBps: 500,
        maxSpreadBps: 1_000,
        maxSlippageBps: 1_000,
        maxPositionDepthBps: 5_000,
        maxLeverageBps: 25_000,
        openingCutoff: 1_200,
        reduceOnlyCutoff: 600,
        compressionWindow: 3_600,
        maxBookLevels: 4,
        collateralDecimals: 6,
        outcomeIndex: outcomeIndex
      }),
      marketGroup: _MARKET_GROUP,
      enabled: true,
      frozen: false
    });
  }

  /// @notice Returns a deep, short-window oracle policy for one outcome.
  /// @param key Full generation tuple.
  /// @return config Immutable oracle policy.
  function _oraclePolicy(MarketKey memory key) private pure returns (OracleConfig memory config) {
    config = OracleConfig({
      key: key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: _DEPTH_QUANTITY,
      maxObservations: 8,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Sets executable depth producing 0.50 YES and 0.40 NO conservative marks.
  function _setBook() private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: 500_000, quantity: 500 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 600_000, quantity: 500 * _ONE});
    _pool.setBookLevels(true, bids);
    _pool.setBookLevels(false, asks);
  }

  /// @notice Returns the module record for the current test generation.
  /// @return record Complete DreamDEX module market record.
  function _moduleMarket() private view returns (MockModuleMarket memory record) {
    record = MockModuleMarket({
      oracleQuestionId: 1,
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

  /// @notice Returns the recyclable pool binding used by all test generations.
  /// @return info Complete pool generation record.
  function _poolInfo() private view returns (IDreamDexBinaryPool.BinaryPoolInfo memory info) {
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
      marketNonce: 1,
      finalized: false
    });
  }

  /// @notice Derives one full generation identity.
  /// @param key Full tuple hashed.
  /// @return generationKey Generation identifier.
  function _deriveKey(MarketKey memory key) private pure returns (bytes32 generationKey) {
    generationKey = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
  }
}

// forge-lint: disable-end(unused-return)
