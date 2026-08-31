// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position-reduction tests
/// @author DreamMargin contributors
/// @notice Verifies debt-first repayment, collateral release, deleveraging, and terminal close.
/// @dev Every case runs through the controller against complete vault, oracle, and DreamDEX models.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
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

/// @notice Exercises all ordinary position reductions through immutable lifecycle facets.
contract PositionCloseTest is Test {
  uint256 private constant _ONE = 1e6;
  uint128 private constant _DEPTH_QUANTITY = 100_000_000;
  uint256 private constant _START = 1_000_000;
  uint64 private constant _EXPIRY = 2_000_000;
  uint40 private constant _DELAY = 1 days;
  uint256 private constant _ANNUAL_RATE_WAD = 1e17;
  bytes32 private constant _MARKET_ID = keccak256("position-close-market");
  bytes32 private constant _MARKET_GROUP = keccak256("position-close-group");
  bytes32 private constant _CHANGE_ID = keccak256("register-close-generation");
  uint256 private constant _YES_ID = 81;
  uint256 private constant _NO_ID = 82;
  address private constant _SETTLEMENT = address(0x5151);
  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _LP = address(0x2001);
  address private constant _OWNER = address(0x2002);
  address private constant _PAYER = address(0x2003);
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
  DreamMarginControllerHarness private _controller;
  MarketKey private _key;
  bytes32 private _generationKey;

  /// @notice Deploys and matures one complete generation with cash and execution inventory.
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

    uint256 nextNonce = vm.getNonce(address(this));
    address predictedController = vm.computeCreateAddress(address(this), nextNonce + 2);
    _vault = new DreamMarginVault(address(_collateral), predictedController, _ANNUAL_RATE_WAD);
    _oracle = new DreamDexMarkOracle(address(_module), predictedController);
    _controller = new DreamMarginControllerHarness(
      address(_module),
      address(_vault),
      address(_oracle),
      _FEE_RECIPIENT,
      address(_positionOpen),
      address(_positionClose),
      address(_positionLiquidation),
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
    vm.prank(_PAYER);
    _collateral.approve(address(_controller), type(uint256).max);
  }

  /// @notice Lets an unrelated payer retire debt without changing ownership or outcome custody.
  function test_thirdPartyRepayUpdatesEveryDebtBucketOnly() external {
    uint256 positionId = _open();
    Position memory beforePosition = _controller.getPosition(positionId);

    vm.prank(_PAYER);
    uint256 assetsRepaid = _controller.repay(positionId, 5 * _ONE);
    Position memory afterPosition = _controller.getPosition(positionId);

    assertGt(assetsRepaid, 0);
    assertLe(assetsRepaid, 5 * _ONE);
    assertLt(afterPosition.debtShares, beforePosition.debtShares);
    assertEq(afterPosition.shares, beforePosition.shares);
    assertEq(afterPosition.owner, _OWNER);
    assertEq(_outcome.balanceOf(address(_controller), _YES_ID), afterPosition.shares);
    _assertAggregates(afterPosition.shares, afterPosition.debtShares);
  }

  /// @notice Rejects a partial repayment that would strand debt below the configured minimum.
  function test_repayRejectsMinimumDebtDustAtomically() external {
    uint256 positionId = _open();
    Position memory beforePosition = _controller.getPosition(positionId);

    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.DebtCapExceeded.selector);
    _controller.repay(positionId, 9_500_000);

    Position memory afterPosition = _controller.getPosition(positionId);
    assertEq(afterPosition.debtShares, beforePosition.debtShares);
    _assertAggregates(afterPosition.shares, afterPosition.debtShares);
  }

  /// @notice Accrues the debt index and still permits a bounded full repayment after expiry.
  function test_repayUsesCurrentDebtIndexAndRemainsAvailableAfterExpiry() external {
    uint256 positionId = _open();
    uint256 oldIndex = _vault.debtIndexWad();
    vm.warp(_EXPIRY + 1);
    uint256 currentDebt = _vault.debtAssets(_controller.getPosition(positionId).debtShares);
    assertGt(_vault.debtIndexWad(), oldIndex);

    vm.prank(_OWNER);
    uint256 assetsRepaid = _controller.repay(positionId, currentDebt);

    assertEq(assetsRepaid, currentDebt);
    assertEq(_controller.getPosition(positionId).debtShares, 0);
    _assertAggregates(40 * _ONE, 0);
  }

  /// @notice Releases conservatively excess collateral only after repayment makes it healthy.
  function test_withdrawCollateralChecksPostWithdrawalHealthAndCustody() external {
    uint256 positionId = _open();
    vm.prank(_OWNER);
    _controller.repay(positionId, 6 * _ONE);
    uint256 ownerBefore = _outcome.balanceOf(_OWNER, _YES_ID);

    vm.prank(_OWNER);
    _controller.withdrawCollateral(positionId, 10 * _ONE);

    Position memory position = _controller.getPosition(positionId);
    assertEq(position.shares, 30 * _ONE);
    assertEq(_outcome.balanceOf(_OWNER, _YES_ID), ownerBefore + 10 * _ONE);
    _assertAggregates(position.shares, position.debtShares);
  }

  /// @notice Rolls back an outcome release that would violate initial or maintenance health.
  function test_withdrawCollateralRejectsUnsafeRelease() external {
    uint256 positionId = _open();
    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.InsufficientHealth.selector);
    _controller.withdrawCollateral(positionId, 10 * _ONE);

    Position memory position = _controller.getPosition(positionId);
    assertEq(position.shares, 40 * _ONE);
    _assertAggregates(position.shares, position.debtShares);
  }

  /// @notice Stale pricing blocks leveraged release but never traps debt-free collateral.
  function test_staleOracleBlocksLeveragedWithdrawalButNotDebtFreeWithdrawal() external {
    uint256 positionId = _open();
    vm.warp(block.timestamp + 121);

    vm.prank(_OWNER);
    vm.expectRevert();
    _controller.withdrawCollateral(positionId, _ONE);

    vm.prank(_OWNER);
    _controller.repay(positionId, 50 * _ONE);
    vm.prank(_OWNER);
    _controller.withdrawCollateral(positionId, 40 * _ONE);
    Position memory position = _controller.getPosition(positionId);
    assertEq(uint8(position.status), uint8(PositionStatus.CLOSED));
    _assertAggregates(0, 0);
  }

  /// @notice Applies actual partial-fill proceeds to debt before exposing any owner collateral.
  function test_deleverageUsesActualFillAndDebtFirstProceeds() external {
    uint256 positionId = _open();
    _pool.setExecution(5_000, 0);
    uint256 ownerAssetsBefore = _collateral.balanceOf(_OWNER);

    vm.prank(_OWNER);
    (uint256 sharesSold, uint256 assetsRepaid) =
      _controller.deleverage(_deleverage(positionId, 20 * _ONE, 500_000));

    Position memory position = _controller.getPosition(positionId);
    assertEq(sharesSold, 10 * _ONE);
    assertGt(assetsRepaid, 0);
    assertEq(position.shares, 30 * _ONE);
    assertEq(_collateral.balanceOf(_OWNER), ownerAssetsBefore);
    _assertAggregates(position.shares, position.debtShares);
  }

  /// @notice Rejects a sale whose low execution price worsens debt per retained outcome share.
  function test_deleverageRejectsWorseningPartialReductionAtomically() external {
    uint256 positionId = _open();
    Position memory beforePosition = _controller.getPosition(positionId);

    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.InsufficientHealth.selector);
    _controller.deleverage(_deleverage(positionId, 10 * _ONE, 100_000));

    Position memory afterPosition = _controller.getPosition(positionId);
    assertEq(afterPosition.shares, beforePosition.shares);
    assertEq(afterPosition.debtShares, beforePosition.debtShares);
    _assertAggregates(afterPosition.shares, afterPosition.debtShares);
  }

  /// @notice Returns sale proceeds only after prior repayment has reduced position debt to zero.
  function test_debtFreeDeleverageReturnsAllActualProceeds() external {
    uint256 positionId = _open();
    vm.prank(_OWNER);
    _controller.repay(positionId, 50 * _ONE);
    uint256 ownerBefore = _collateral.balanceOf(_OWNER);

    vm.prank(_OWNER);
    (uint256 sharesSold, uint256 assetsRepaid) =
      _controller.deleverage(_deleverage(positionId, 10 * _ONE, 500_000));

    assertEq(sharesSold, 10 * _ONE);
    assertEq(assetsRepaid, 0);
    assertEq(_collateral.balanceOf(_OWNER), ownerBefore + 5 * _ONE);
    _assertAggregates(30 * _ONE, 0);
  }

  /// @notice Sells every attributed share, repays current debt, and returns only true surplus.
  function test_closeBySaleZerosPositionAndAllAggregates() external {
    uint256 positionId = _open();
    uint256 ownerBefore = _collateral.balanceOf(_OWNER);

    vm.prank(_OWNER);
    (uint256 assetsOut, uint256 sharesOut) = _controller.close(_saleClose(positionId, 0));

    Position memory position = _controller.getPosition(positionId);
    assertGt(assetsOut, 9 * _ONE);
    assertEq(sharesOut, 0);
    assertEq(_collateral.balanceOf(_OWNER), ownerBefore + assetsOut);
    assertEq(position.shares, 0);
    assertEq(position.debtShares, 0);
    assertEq(uint8(position.status), uint8(PositionStatus.CLOSED));
    _assertAggregates(0, 0);
  }

  /// @notice Rolls back an IOC close unless every attributed outcome share actually sells.
  function test_closeRejectsPartialFillAtomically() external {
    uint256 positionId = _open();
    Position memory beforePosition = _controller.getPosition(positionId);
    _pool.setExecution(5_000, 0);

    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.IncompleteClose.selector);
    _controller.close(_saleClose(positionId, 0));

    Position memory afterPosition = _controller.getPosition(positionId);
    assertEq(afterPosition.shares, beforePosition.shares);
    assertEq(afterPosition.debtShares, beforePosition.debtShares);
    assertEq(uint8(afterPosition.status), uint8(PositionStatus.ACTIVE));
    _assertAggregates(afterPosition.shares, afterPosition.debtShares);
  }

  /// @notice Requires a bounded owner top-up when sale proceeds cannot fully retire the debt.
  function test_closeRejectsInsufficientDebtTopUpAtomically() external {
    uint256 positionId = _open();
    IDreamMarginController.CloseParams memory params = _saleClose(positionId, 5 * _ONE);
    params.limitPrice = 100_000;

    vm.prank(_OWNER);
    vm.expectPartialRevert(LibDreamMarginErrors.RepaymentLimitExceeded.selector);
    _controller.close(params);

    Position memory position = _controller.getPosition(positionId);
    assertEq(uint8(position.status), uint8(PositionStatus.ACTIVE));
    _assertAggregates(position.shares, position.debtShares);
  }

  /// @notice Supports repaying externally and withdrawing the exact outcome ID without a sale.
  function test_closeByOutcomeWithdrawalReturnsExactShares() external {
    uint256 positionId = _open();
    uint256 ownerBefore = _outcome.balanceOf(_OWNER, _YES_ID);

    vm.prank(_OWNER);
    (uint256 assetsOut, uint256 sharesOut) = _controller.close(_withdrawClose(positionId));

    assertEq(assetsOut, 0);
    assertEq(sharesOut, 40 * _ONE);
    assertEq(_outcome.balanceOf(_OWNER, _YES_ID), ownerBefore + sharesOut);
    Position memory position = _controller.getPosition(positionId);
    assertEq(uint8(position.status), uint8(PositionStatus.CLOSED));
    _assertAggregates(0, 0);
  }

  /// @notice Keeps every debt-reducing exit available in the most restrictive emergency mode.
  function test_pausedModeStillAllowsRepayDeleverageAndClose() external {
    uint256 positionId = _open();
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);

    vm.prank(_PAYER);
    _controller.repay(positionId, 2 * _ONE);
    vm.prank(_OWNER);
    _controller.deleverage(_deleverage(positionId, 10 * _ONE, 500_000));
    vm.prank(_OWNER);
    _controller.close(_saleClose(positionId, 0));

    Position memory position = _controller.getPosition(positionId);
    assertEq(uint8(position.status), uint8(PositionStatus.CLOSED));
    _assertAggregates(0, 0);
  }

  /// @notice Restricts collateral release and exits to the owner while keeping repayment public.
  function test_nonOwnerCannotWithdrawDeleverageOrClose() external {
    uint256 positionId = _open();

    vm.startPrank(_STRANGER);
    vm.expectPartialRevert(LibDreamMarginErrors.NotPositionOwner.selector);
    _controller.withdrawCollateral(positionId, _ONE);
    vm.expectPartialRevert(LibDreamMarginErrors.NotPositionOwner.selector);
    _controller.deleverage(_deleverage(positionId, _ONE, 500_000));
    vm.expectPartialRevert(LibDreamMarginErrors.NotPositionOwner.selector);
    _controller.close(_saleClose(positionId, 0));
    vm.stopPrank();
  }

  /// @notice Pins the close facet and prevents bypassing controller storage and its shared lock.
  function test_closeFacetIsPinnedAndCannotBeCalledDirectly() external {
    assertEq(_controller.positionCloseFacet(), address(_positionClose));
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ReentrantCall.selector, uint8(0)));
    _positionClose.repay(1, _ONE);
  }

  /// @notice Opens one standard 2x YES position and returns its identifier.
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

  /// @notice Returns one bounded outcome-sale reduction.
  /// @param positionId Position reduced.
  /// @param shares Maximum shares offered.
  /// @param price YES-side sale price.
  /// @return params Complete deleverage request.
  function _deleverage(uint256 positionId, uint256 shares, uint256 price)
    private
    view
    returns (IDreamMarginController.DeleverageParams memory params)
  {
    params = IDreamMarginController.DeleverageParams({
      positionId: positionId,
      sharesToSell: shares,
      minCollateralOut: 0,
      limitPrice: price,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600
    });
  }

  /// @notice Returns a sale-based terminal close request.
  /// @param positionId Position closed.
  /// @param maxTopUp Maximum owner collateral pulled for a debt shortfall.
  /// @return params Complete close request.
  function _saleClose(uint256 positionId, uint256 maxTopUp)
    private
    view
    returns (IDreamMarginController.CloseParams memory params)
  {
    params = IDreamMarginController.CloseParams({
      positionId: positionId,
      maxRepayAssets: maxTopUp,
      minCollateralOut: 0,
      limitPrice: 500_000,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600,
      withdrawOutcome: false
    });
  }

  /// @notice Returns an externally repaid outcome-withdrawal close request.
  /// @param positionId Position closed.
  /// @return params Complete close request.
  function _withdrawClose(uint256 positionId)
    private
    view
    returns (IDreamMarginController.CloseParams memory params)
  {
    params = IDreamMarginController.CloseParams({
      positionId: positionId,
      maxRepayAssets: 50 * _ONE,
      minCollateralOut: 0,
      limitPrice: 0,
      orderType: 0,
      deadline: block.timestamp,
      withdrawOutcome: true
    });
  }

  /// @notice Asserts exact custody and all three debt attribution buckets.
  /// @param expectedShares Expected exact-ID controller custody.
  /// @param expectedDebtShares Expected debt shares in every aggregate.
  function _assertAggregates(uint256 expectedShares, uint256 expectedDebtShares) private view {
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

  /// @notice Funds vault cash, owner payments, and both pool-side execution assets.
  function _fundAccounts() private {
    _collateral.mint(_LP, 1_000 * _ONE);
    vm.startPrank(_LP);
    _collateral.approve(address(_vault), type(uint256).max);
    _vault.deposit(1_000 * _ONE, _LP);
    vm.stopPrank();
    _collateral.mint(_OWNER, 100 * _ONE);
    _collateral.mint(_PAYER, 100 * _ONE);
    _collateral.mint(address(_pool), 500 * _ONE);
    _outcome.mint(_OWNER, _YES_ID, 100 * _ONE);
    _outcome.mint(address(_pool), _YES_ID, 500 * _ONE);
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

  /// @notice Returns global admission and delayed-governance bounds.
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

  /// @notice Returns the bounded exact-generation policy used by reduction tests.
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

  /// @notice Returns the short-window oracle policy used for withdrawal health.
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

  /// @notice Sets a deep executable 0.50 YES book.
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
