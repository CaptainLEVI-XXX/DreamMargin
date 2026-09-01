// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position-liquidation tests
/// @author DreamMargin contributors
/// @notice Verifies permissionless eligibility, collateral take, direct sale, and atomic recovery.
/// @dev Tests use complete controller, vault, oracle, and mutable DreamDEX integration models.

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
import {MockCallbackERC20} from "test/mock/AdversarialERC20.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";

// Expected-revert lifecycle calls intentionally ignore returned values.
// forge-lint: disable-start(unused-return)

/// @notice Exercises both liquidation routes and their adversarial state boundaries.
contract PositionLiquidationTest is Test {
  uint256 private constant _ONE = 1e6;
  uint128 private constant _DEPTH_QUANTITY = 100_000_000;
  uint256 private constant _START = 1_000_000;
  uint64 private constant _EXPIRY = 2_000_000;
  uint40 private constant _DELAY = 1 days;
  bytes32 private constant _MARKET_ID = keccak256("position-liquidation-market");
  bytes32 private constant _MARKET_GROUP = keccak256("position-liquidation-group");
  bytes32 private constant _CHANGE_ID = keccak256("register-liquidation-generation");
  uint256 private constant _YES_ID = 91;
  uint256 private constant _NO_ID = 92;
  address private constant _SETTLEMENT = address(0x5151);
  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _LP = address(0x2001);
  address private constant _OWNER = address(0x2002);
  address private constant _LIQUIDATOR = address(0x2003);
  address private constant _COMPETITOR = address(0x2004);

  MockCallbackERC20 private _collateral;
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
  MarketKey private _key;
  bytes32 private _generationKey;

  /// @notice Deploys, funds, registers, and matures one complete YES generation.
  function setUp() external {
    vm.warp(_START);
    _collateral = new MockCallbackERC20();
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
    _setBook(500_000);
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

    _key = MarketKey({
      marketId: _MARKET_ID,
      pool: address(_pool),
      marketNonce: 1,
      outcomeToken: address(_outcome),
      outcomeId: _YES_ID,
      collateral: address(_collateral)
    });
    _generationKey = _deriveKey(_key);
    _fundAccounts();
    GenerationConfig memory generation = _generation();
    OracleConfig memory oraclePolicy = _oraclePolicy();
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(_CHANGE_ID, _generationKey, generation, oraclePolicy);
    vm.warp(_START + _DELAY);
    _controller.executeGenerationChange(_CHANGE_ID, _generationKey, generation, oraclePolicy);
    _oracle.observe(_generationKey);
    vm.warp(block.timestamp + 60);
    _oracle.observe(_generationKey);

    vm.startPrank(_OWNER);
    _outcome.approve(address(_controller), _YES_ID, type(uint256).max);
    _collateral.approve(address(_controller), type(uint256).max);
    vm.stopPrank();
    vm.prank(_LIQUIDATOR);
    _collateral.approve(address(_controller), type(uint256).max);
    vm.prank(_COMPETITOR);
    _collateral.approve(address(_controller), type(uint256).max);
  }

  /// @notice Rejects a position whose conservative LTV remains at or above maintenance health.
  function test_healthyPositionCannotBeLiquidated() external {
    uint256 positionId = _open();
    vm.prank(_LIQUIDATOR);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.PositionNotLiquidatable.selector, positionId, 6_250, 7_500
      )
    );
    _controller.liquidate(_take(positionId, 10 * _ONE, 0));
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Treats the exact maintenance-LTV boundary as healthy rather than liquidatable.
  function test_exactMaintenanceBoundaryCannotBeLiquidated() external {
    uint256 positionId = _open();
    _makeUnhealthy(416_667);

    vm.prank(_LIQUIDATOR);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.PositionNotLiquidatable.selector, positionId, 7_500, 7_500
      )
    );
    _controller.liquidate(_take(positionId, 10 * _ONE, 0));
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Partially repays and seizes only enough discounted collateral to restore initial health.
  function test_collateralTakeRestoresHealthAndEveryAggregate() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    uint256 liquidatorAssetsBefore = _collateral.balanceOf(_LIQUIDATOR);

    vm.prank(_LIQUIDATOR);
    (uint256 repaid, uint256 seized, uint256 incentive) =
      _controller.liquidate(_take(positionId, 7 * _ONE, 18 * _ONE));

    assertEq(repaid, 7 * _ONE);
    assertEq(seized, 18_375_000);
    assertEq(incentive, 350_000);
    assertEq(_collateral.balanceOf(_LIQUIDATOR), liquidatorAssetsBefore - repaid);
    assertEq(_outcome.balanceOf(_LIQUIDATOR, _YES_ID), seized);
    _assertPosition(positionId, 21_625_000, 3 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Rolls back payment and seizure when a partial take does not restore initial health.
  function test_collateralTakeRejectsInsufficientPaymentAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    uint256 assetsBefore = _collateral.balanceOf(_LIQUIDATOR);

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.InsufficientHealth.selector);
    _controller.liquidate(_take(positionId, 4 * _ONE, 0));

    assertEq(_collateral.balanceOf(_LIQUIDATOR), assetsBefore);
    assertEq(_outcome.balanceOf(_LIQUIDATOR, _YES_ID), 0);
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Honors the liquidator's minimum exact-ID share output before committing repayment.
  function test_collateralTakeHonorsMinimumSharesOutAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);

    vm.prank(_LIQUIDATOR);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InsufficientSharesOut.selector, 18_375_000, 19 * _ONE
      )
    );
    _controller.liquidate(_take(positionId, 7 * _ONE, 19 * _ONE));
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Allows a full cash-backed collateral take when deep impairment consumes all shares.
  function test_collateralTakeCanReachTerminalZeroState() external {
    uint256 positionId = _open();
    _makeUnhealthy(200_000);

    vm.prank(_LIQUIDATOR);
    (uint256 repaid, uint256 seized, uint256 incentive) =
      _controller.liquidate(_take(positionId, 10 * _ONE, 40 * _ONE));

    assertEq(repaid, 10 * _ONE);
    assertEq(seized, 40 * _ONE);
    assertEq(incentive, 0);
    _assertPosition(positionId, 0, 0, PositionStatus.CLOSED);
  }

  /// @notice Permits self-liquidation without creating any claim beyond the owner's own shares.
  function test_selfLiquidationUsesTheSameBoundedCollateralTake() external {
    uint256 positionId = _open();
    _makeUnhealthy(200_000);
    uint256 ownerOutcomesBefore = _outcome.balanceOf(_OWNER, _YES_ID);

    vm.prank(_OWNER);
    (, uint256 seized,) = _controller.liquidate(_take(positionId, 10 * _ONE, 40 * _ONE));

    assertEq(seized, 40 * _ONE);
    assertEq(_outcome.balanceOf(_OWNER, _YES_ID), ownerOutcomesBefore + seized);
    _assertPosition(positionId, 0, 0, PositionStatus.CLOSED);
  }

  /// @notice Sells all collateral, retires debt, and pays bonus only from genuine sale surplus.
  function test_directSaleClosesAndSplitsPostDebtSurplus() external {
    uint256 positionId = _open();
    _makeUnhealthy(300_000);
    uint256 ownerAssetsBefore = _collateral.balanceOf(_OWNER);
    uint256 liquidatorAssetsBefore = _collateral.balanceOf(_LIQUIDATOR);

    vm.prank(_LIQUIDATOR);
    (uint256 repaid, uint256 seized, uint256 incentive) =
      _controller.liquidate(_sale(positionId, 10 * _ONE, 300_000));

    assertEq(repaid, 10 * _ONE);
    assertEq(seized, 40 * _ONE);
    assertEq(incentive, 500_000);
    assertEq(_collateral.balanceOf(_LIQUIDATOR), liquidatorAssetsBefore + incentive);
    assertEq(_collateral.balanceOf(_OWNER), ownerAssetsBefore + 1_500_000);
    _assertPosition(positionId, 0, 0, PositionStatus.CLOSED);
  }

  /// @notice Uses actual IOC sale deltas and releases no value while partial debt remains.
  function test_directSalePartialFillRestoresHealthDebtFirst() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    _pool.setExecution(5_000, 0);
    uint256 ownerAssetsBefore = _collateral.balanceOf(_OWNER);
    uint256 liquidatorAssetsBefore = _collateral.balanceOf(_LIQUIDATOR);

    vm.prank(_LIQUIDATOR);
    (uint256 repaid, uint256 seized, uint256 incentive) =
      _controller.liquidate(_sale(positionId, 10 * _ONE, 400_000));

    assertEq(repaid, 8 * _ONE);
    assertEq(seized, 20 * _ONE);
    assertEq(incentive, 0);
    assertEq(_collateral.balanceOf(_OWNER), ownerAssetsBefore);
    assertEq(_collateral.balanceOf(_LIQUIDATOR), liquidatorAssetsBefore);
    _assertPosition(positionId, 20 * _ONE, 2 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Rejects an actual IOC fill that leaves the position above required post-health.
  function test_directSaleRejectsUnsafePartialFillAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    _pool.setExecution(2_500, 0);

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.InsufficientHealth.selector);
    _controller.liquidate(_sale(positionId, 10 * _ONE, 400_000));

    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
    assertEq(_pool.fillBps(), 2_500);
  }

  /// @notice Rejects a partial FOK execution before any position or vault state can change.
  function test_directSaleFokRejectsPartialExecutionAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    _pool.setExecution(5_000, 0);
    IDreamMarginController.LiquidationParams memory params = _sale(positionId, 10 * _ONE, 400_000);
    params.orderType = LibDreamMarginConstants.ORDER_TYPE_FOK;

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.OrderRejected.selector);
    _controller.liquidate(params);
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Rejects a zero-fill IOC liquidation without consuming collateral or debt.
  function test_directSaleRejectsZeroFillAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    _pool.setExecution(0, 0);

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.OrderRejected.selector);
    _controller.liquidate(_sale(positionId, 10 * _ONE, 400_000));
    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Enforces the direct-sale debt bound and rejects zero-collateral debt remnants.
  function test_directSaleRejectsBoundedUnderRepaymentAtomically() external {
    uint256 positionId = _open();
    _makeUnhealthy(300_000);

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.IncompleteClose.selector);
    _controller.liquidate(_sale(positionId, 5 * _ONE, 300_000));

    _assertPosition(positionId, 40 * _ONE, 10 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Fails closed when the TWAP is stale even though a current executable book exists.
  function test_staleOracleBlocksBothLiquidationRoutes() external {
    uint256 positionId = _open();
    _makeUnhealthy(300_000);
    vm.warp(block.timestamp + 121);

    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.StaleOracle.selector);
    _controller.liquidate(_take(positionId, 10 * _ONE, 0));
    vm.prank(_LIQUIDATOR);
    vm.expectPartialRevert(LibDreamMarginErrors.StaleOracle.selector);
    _controller.liquidate(_sale(positionId, 10 * _ONE, 300_000));
  }

  /// @notice Routes resolved markets exclusively to settlement rather than ordinary liquidation.
  function test_terminalStatusCannotUseOrdinaryLiquidation() external {
    uint256 positionId = _open();
    uint256[] memory payouts = new uint256[](2);
    payouts[0] = 1;
    _market.resolve(payouts, false);

    vm.prank(_LIQUIDATOR);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidMarketStatus.selector,
        address(_market),
        uint8(LibDreamMarginConstants.MARKET_STATUS_RESOLVED),
        uint8(LibDreamMarginConstants.MARKET_STATUS_TRADING)
      )
    );
    _controller.liquidate(_take(positionId, 10 * _ONE, 0));
  }

  /// @notice Preserves liquidation liveness in the most restrictive protocol mode.
  function test_pausedModeStillAllowsLiquidation() external {
    uint256 positionId = _open();
    _makeUnhealthy(200_000);
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);

    vm.prank(_LIQUIDATOR);
    _controller.liquidate(_take(positionId, 10 * _ONE, 40 * _ONE));
    _assertPosition(positionId, 0, 0, PositionStatus.CLOSED);
  }

  /// @notice Makes a second competing liquidation fail after the first restores required health.
  function test_competingLiquidatorCannotSeizeFromRestoredPosition() external {
    uint256 positionId = _open();
    _makeUnhealthy(400_000);
    vm.prank(_LIQUIDATOR);
    _controller.liquidate(_take(positionId, 7 * _ONE, 0));

    vm.prank(_COMPETITOR);
    vm.expectPartialRevert(LibDreamMarginErrors.PositionNotLiquidatable.selector);
    _controller.liquidate(_take(positionId, 3 * _ONE, 0));
    _assertPosition(positionId, 21_625_000, 3 * _ONE, PositionStatus.ACTIVE);
  }

  /// @notice Reaches a collateral callback and rejects reentry through the shared lifecycle lock.
  function test_liquidatorPaymentCallbackCannotReenter() external {
    uint256 positionId = _open();
    _makeUnhealthy(200_000);
    IDreamMarginController.LiquidationParams memory params = _take(positionId, 10 * _ONE, 40 * _ONE);
    _collateral.configureCallback(
      address(_controller), abi.encodeCall(IDreamMarginController.liquidate, (params))
    );

    vm.prank(_LIQUIDATOR);
    _controller.liquidate(params);

    assertFalse(_collateral.lastCallbackSucceeded());
    assertEq(
      _collateral.lastCallbackReturnData(),
      abi.encodeWithSelector(
        LibDreamMarginErrors.ReentrantCall.selector, LibDreamMarginConstants.REENTRANCY_LOCKED
      )
    );
    _assertPosition(positionId, 0, 0, PositionStatus.CLOSED);
  }

  /// @notice Pins the liquidation facet and prevents bypassing controller storage and its lock.
  function test_liquidationFacetIsPinnedAndCannotBeCalledDirectly() external {
    assertEq(_controller.positionLiquidationFacet(), address(_positionLiquidation));
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ReentrantCall.selector, uint8(0)));
    _positionLiquidation.liquidate(_take(1, _ONE, 0));
  }

  /// @notice Opens one standard 2x YES position.
  /// @return positionId Newly allocated position identifier.
  function _open() private returns (uint256 positionId) {
    vm.prank(_OWNER);
    (positionId,,) = _controller.openPosition(
      IDreamMarginController.OpenParams({
        key: _key,
        outcomeIndex: 0,
        initialShares: 20 * _ONE,
        leverageBps: 20_000,
        maxCollateralIn: 10 * _ONE,
        minSharesOut: 20 * _ONE,
        limitPrice: 500_000,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600
      })
    );
  }

  /// @notice Returns one collateral-take liquidation request.
  /// @param positionId Position liquidated.
  /// @param maxDebtAssets Maximum liquidator collateral paid.
  /// @param minSharesOut Minimum exact-ID outcomes received.
  /// @return params Complete request.
  function _take(uint256 positionId, uint256 maxDebtAssets, uint256 minSharesOut)
    private
    view
    returns (IDreamMarginController.LiquidationParams memory params)
  {
    params = IDreamMarginController.LiquidationParams({
      positionId: positionId,
      maxDebtAssets: maxDebtAssets,
      minSharesOut: minSharesOut,
      minCollateralOut: 0,
      limitPrice: 0,
      orderType: 0,
      deadline: block.timestamp,
      route: IDreamMarginController.LiquidationRoute.COLLATERAL_TAKE
    });
  }

  /// @notice Returns one direct-sale liquidation request.
  /// @param positionId Position liquidated.
  /// @param maxDebtAssets Maximum sale proceeds applied to debt.
  /// @param price YES-side sale limit.
  /// @return params Complete request.
  function _sale(uint256 positionId, uint256 maxDebtAssets, uint256 price)
    private
    view
    returns (IDreamMarginController.LiquidationParams memory params)
  {
    params = IDreamMarginController.LiquidationParams({
      positionId: positionId,
      maxDebtAssets: maxDebtAssets,
      minSharesOut: 0,
      minCollateralOut: 0,
      limitPrice: price,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600,
      route: IDreamMarginController.LiquidationRoute.DIRECT_SALE
    });
  }

  /// @notice Moves the current executable recovery below maintenance and records a fresh sample.
  /// @param bidPrice Replacement YES bid and direct-sale price.
  function _makeUnhealthy(uint256 bidPrice) private {
    _setBook(bidPrice);
    vm.warp(block.timestamp + 30);
    _oracle.observe(_generationKey);
  }

  /// @notice Asserts one position plus exact custody and all debt-attribution buckets.
  /// @param positionId Position checked.
  /// @param expectedShares Expected attributed shares.
  /// @param expectedDebtShares Expected debt shares.
  /// @param expectedStatus Expected lifecycle status.
  function _assertPosition(
    uint256 positionId,
    uint256 expectedShares,
    uint256 expectedDebtShares,
    PositionStatus expectedStatus
  ) private view {
    Position memory position = _controller.getPosition(positionId);
    assertEq(position.shares, expectedShares);
    assertEq(position.debtShares, expectedDebtShares);
    assertEq(uint8(position.status), uint8(expectedStatus));
    (
      uint256 attributedShares,
      uint256 outcomeDebtShares,
      uint256 marketDebtShares,
      uint256 totalDebtShares
    ) = _controller.aggregateState(_generationKey, _MARKET_GROUP, address(_outcome), _YES_ID);
    assertEq(attributedShares, expectedShares);
    assertEq(outcomeDebtShares, expectedDebtShares);
    assertEq(marketDebtShares, expectedDebtShares);
    assertEq(totalDebtShares, expectedDebtShares);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), expectedShares);
    assertEq(_vault.totalDebtShares(), expectedDebtShares);
  }

  /// @notice Funds vault cash, repayment accounts, and both pool execution assets.
  function _fundAccounts() private {
    _collateral.mint(_LP, 1_000 * _ONE);
    vm.startPrank(_LP);
    _collateral.approve(address(_vault), type(uint256).max);
    _vault.deposit(1_000 * _ONE, _LP);
    vm.stopPrank();
    _collateral.mint(_OWNER, 100 * _ONE);
    _collateral.mint(_LIQUIDATOR, 100 * _ONE);
    _collateral.mint(_COMPETITOR, 100 * _ONE);
    _collateral.mint(address(_pool), 500 * _ONE);
    _outcome.mint(_OWNER, _YES_ID, 100 * _ONE);
    _outcome.mint(address(_pool), _YES_ID, 500 * _ONE);
  }

  /// @notice Returns separated initial administrative roles.
  /// @return roles Initial role assignment.
  function _initialRoles() private pure returns (DreamMarginController.InitialRoles memory roles) {
    roles = DreamMarginController.InitialRoles({
      governance: _GOVERNANCE,
      riskSteward: _RISK_STEWARD,
      guardian: _GUARDIAN,
      feeCollector: _FEE_COLLECTOR
    });
  }

  /// @notice Returns global debt, utilization, loss, and delayed-governance bounds.
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

  /// @notice Returns the exact-generation policy used by liquidation tests.
  /// @return config Controller generation record.
  function _generation() private view returns (GenerationConfig memory config) {
    config = GenerationConfig({
      key: _key,
      risk: RiskConfig({
        maxDebtPerPosition: 20 * _ONE,
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
        outcomeIndex: 0
      }),
      marketGroup: _MARKET_GROUP,
      enabled: true,
      frozen: false
    });
  }

  /// @notice Returns the observation policy used for mature liquidation eligibility.
  /// @return config Immutable oracle generation policy.
  function _oraclePolicy() private view returns (OracleConfig memory config) {
    config = OracleConfig({
      key: _key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: _DEPTH_QUANTITY,
      maxObservations: 8,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Sets a deep uncrossed book with the requested YES bid.
  /// @param bidPrice Highest YES bid.
  function _setBook(uint256 bidPrice) private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: bidPrice, quantity: 500 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    uint256 askPrice = bidPrice == 500_000 ? 600_000 : _ONE - bidPrice;
    asks[0] = IDreamDexBinaryPool.BookLevel({price: askPrice, quantity: 500 * _ONE});
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

  /// @notice Returns the recyclable pool binding used by the test generation.
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
