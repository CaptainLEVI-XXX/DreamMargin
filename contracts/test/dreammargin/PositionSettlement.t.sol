// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position-settlement tests
/// @author DreamMargin contributors
/// @notice Verifies frozen redemption, debt-first loss accounting, reserve use, and finality.
/// @dev Tests use outcome IDs with DreamDEX's exact pool/nonce/index bit encoding.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {PositionSettlement} from "src/dreammargin/base/PositionSettlement.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IDreamDexBinarySettlement} from "src/interfaces/integrations/IDreamDexBinarySettlement.sol";

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
import {MockDreamDexBinarySettlement} from "test/mock/MockDreamDexBinarySettlement.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

// Fixed-width fixture casts are bounded, and expected-revert calls intentionally ignore returns.
// forge-lint: disable-start(unsafe-typecast, unused-return)

/// @notice Exercises terminal settlement against one exact YES generation.
contract PositionSettlementTest is Test {
  uint256 private constant _ONE = 1e6;
  uint128 private constant _DEPTH_QUANTITY = 100_000_000;
  uint256 private constant _START = 1_000_000;
  uint64 private constant _EXPIRY = 2_000_000;
  uint40 private constant _DELAY = 1 days;
  bytes32 private constant _MARKET_ID = keccak256("position-settlement-market");
  bytes32 private constant _MARKET_GROUP = keccak256("position-settlement-group");
  bytes32 private constant _CHANGE_ID = keccak256("register-settlement-generation");
  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _LP = address(0x2001);
  address private constant _OWNER = address(0x2002);
  address private constant _KEEPER = address(0x2003);
  address private constant _FUNDER = address(0x2004);

  MockCallbackERC20 private _collateral;
  MockERC6909 private _outcome;
  MockDreamDexBinarySettlement private _settlement;
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
  uint256 private _yesId;
  uint256 private _noId;

  /// @notice Deploys, funds, registers, and matures one complete encoded generation.
  function setUp() external {
    vm.warp(_START);
    _collateral = new MockCallbackERC20();
    _outcome = new MockERC6909();
    _settlement = new MockDreamDexBinarySettlement(address(_outcome));

    uint256 nextNonce = vm.getNonce(address(this));
    address predictedPool = vm.computeCreateAddress(address(this), nextNonce + 1);
    _yesId = _outcomeId(predictedPool, 1, 0);
    _noId = _outcomeId(predictedPool, 1, 1);
    _market = new MockDreamDexBinaryMarket(
      address(_outcome), _yesId, _noId, predictedPool, address(_collateral), _EXPIRY
    );
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(_poolInfo(), grid, _EXPIRY * 1e9);
    assertEq(address(_pool), predictedPool);

    _module = new MockDreamDexBinaryModule(address(_settlement));
    _module.setMarket(_MARKET_ID, 1, _moduleMarket());
    _setBook();
    _positionOpen = new PositionOpen();
    _positionClose = new PositionClose();
    _positionLiquidation = new PositionLiquidation();
    _positionSettlement = new PositionSettlement();

    nextNonce = vm.getNonce(address(this));
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
      outcomeId: _yesId,
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
    _outcome.approve(address(_controller), _yesId, type(uint256).max);
    _collateral.approve(address(_controller), type(uint256).max);
    vm.stopPrank();
    vm.prank(_FUNDER);
    _collateral.approve(address(_controller), type(uint256).max);
  }

  /// @notice Redeems a winner, retires exact debt, returns only surplus, and closes every bucket.
  function test_winnerRepaysDebtBeforeOwnerSurplus() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    uint256 ownerBefore = _collateral.balanceOf(_OWNER);

    vm.prank(_KEEPER);
    (uint256 repaid, uint256 ownerAssets, uint256 badDebt) = _controller.settle(positionId);

    assertEq(repaid, 10 * _ONE);
    assertEq(ownerAssets, 30 * _ONE);
    assertEq(badDebt, 0);
    assertEq(_collateral.balanceOf(_OWNER), ownerBefore + ownerAssets);
    assertEq(_vault.realizedBadDebt(), 0);
    _assertClosed(positionId);
  }

  /// @notice Uses the already fee-scaled frozen vector without charging settlement fees twice.
  function test_feeScaledWinnerIsNotChargedTwice() external {
    uint256 positionId = _open();
    _finalize(9_900_000, 0, false, 100_000);

    vm.prank(_KEEPER);
    (uint256 repaid, uint256 ownerAssets, uint256 badDebt) = _controller.settle(positionId);

    assertEq(repaid, 10 * _ONE);
    assertEq(ownerAssets, 29_600_000);
    assertEq(badDebt, 0);
    _assertClosed(positionId);
  }

  /// @notice Burns a losing outcome successfully, writes off its debt once, and releases no value.
  function test_loserZeroPayoutRecognizesLossOnce() external {
    uint256 positionId = _open();
    _finalize(0, 10_000_000, false, 0);
    uint256 vaultAssetsBefore = _vault.totalAssets();

    vm.prank(_KEEPER);
    (uint256 repaid, uint256 ownerAssets, uint256 badDebt) = _controller.settle(positionId);

    assertEq(repaid, 0);
    assertEq(ownerAssets, 0);
    assertEq(badDebt, 10 * _ONE);
    assertEq(_vault.realizedBadDebt(), 10 * _ONE);
    assertEq(_vault.totalAssets(), vaultAssetsBefore - badDebt);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));
    _assertClosed(positionId);
  }

  /// @notice Redeems a voided side at one half with no fee and returns post-debt residual.
  function test_voidRedeemsRecordedProportionalPayout() external {
    uint256 positionId = _open();
    _finalize(5_000_000, 5_000_000, true, 0);

    vm.prank(_KEEPER);
    (uint256 repaid, uint256 ownerAssets, uint256 badDebt) = _controller.settle(positionId);

    assertEq(repaid, 10 * _ONE);
    assertEq(ownerAssets, 10 * _ONE);
    assertEq(badDebt, 0);
    _assertClosed(positionId);
  }

  /// @notice Applies partial terminal recovery atomically before writing off only the shortfall.
  function test_partialRecoveryReducesRealizedLoss() external {
    uint256 positionId = _open();
    _finalize(1_250_000, 8_750_000, false, 0);

    vm.prank(_KEEPER);
    (uint256 repaid, uint256 ownerAssets, uint256 badDebt) = _controller.settle(positionId);

    assertEq(repaid, 5 * _ONE);
    assertEq(ownerAssets, 0);
    assertEq(badDebt, 5 * _ONE);
    assertEq(_vault.realizedBadDebt(), 5 * _ONE);
    _assertClosed(positionId);
  }

  /// @notice Applies actual funded reserve after recovery and reports only uncovered LP loss.
  function test_fundedReserveAbsorbsTerminalShortfallFirst() external {
    vm.prank(_FUNDER);
    uint256 reserveShares = _controller.fundReserve(6 * _ONE);
    assertGt(reserveShares, 0);
    uint256 positionId = _open();
    _finalize(0, 10_000_000, false, 0);

    vm.prank(_KEEPER);
    (,, uint256 badDebt) = _controller.settle(positionId);

    assertEq(badDebt, 4 * _ONE);
    assertEq(_vault.realizedBadDebt(), 10 * _ONE);
    assertEq(_vault.protocolReserve(), 0);
    _assertClosed(positionId);
  }

  /// @notice Aggregates loss inside one window and permissionlessly activates reduce-only mode.
  function test_lossThresholdPermissionlesslyActivatesReduceOnly() external {
    uint256 first = _open();
    uint256 second = _open();
    _finalize(0, 10_000_000, false, 0);

    vm.prank(_KEEPER);
    _controller.settle(first);
    (uint256 lossBefore,,) = _controller.lossState();
    assertEq(lossBefore, 10 * _ONE);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));

    vm.prank(_KEEPER);
    _controller.settle(second);
    (uint256 lossAfter,, uint40 triggeredAt) = _controller.lossState();
    assertEq(lossAfter, 20 * _ONE);
    assertEq(triggeredAt, block.timestamp);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.REDUCE_ONLY));
  }

  /// @notice Requires both governance delay and the longer loss cooldown before risk restoration.
  function test_lossTriggeredReduceOnlyCannotBeRestoredBeforeCooldown() external {
    uint256 first = _open();
    uint256 second = _open();
    _finalize(0, 10_000_000, false, 0);
    vm.prank(_KEEPER);
    _controller.settle(first);
    vm.prank(_KEEPER);
    _controller.settle(second);
    (,, uint40 triggeredAt) = _controller.lossState();

    bytes32 changeId = keccak256("restore-after-loss");
    bytes32 payload =
      keccak256(abi.encode(_controller.executeModeChange.selector, ProtocolMode.ACTIVE));
    vm.prank(_GOVERNANCE);
    _controller.scheduleChange(changeId, payload);
    vm.warp(block.timestamp + _DELAY);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.ChangeNotReady.selector,
        changeId,
        uint256(triggeredAt) + 2 days,
        block.timestamp
      )
    );
    _controller.executeModeChange(changeId, ProtocolMode.ACTIVE);

    vm.warp(uint256(triggeredAt) + 2 days);
    _controller.executeModeChange(changeId, ProtocolMode.ACTIVE);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));
  }

  /// @notice Starts a fresh fixed loss bucket after the configured window elapses.
  function test_elapsedLossWindowDoesNotAccumulateOldLoss() external {
    uint256 first = _open();
    uint256 second = _open();
    _finalize(0, 10_000_000, false, 0);
    vm.prank(_KEEPER);
    _controller.settle(first);

    vm.warp(block.timestamp + 1 days);
    vm.prank(_KEEPER);
    _controller.settle(second);

    (uint256 dailyLoss, uint40 startedAt, uint40 triggeredAt) = _controller.lossState();
    assertEq(dailyLoss, 10 * _ONE);
    assertEq(startedAt, block.timestamp);
    assertEq(triggeredAt, 0);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));
  }

  /// @notice Preserves permissionless settlement liveness in the most restrictive mode.
  function test_settlementRemainsAvailableWhilePaused() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);

    vm.prank(_KEEPER);
    _controller.settle(positionId);

    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.PAUSED));
    _assertClosed(positionId);
  }

  /// @notice Rejects a terminal-looking market until the permanent record is actually frozen.
  function test_unfinalizedSettlementRecordRevertsAtomically() external {
    uint256 positionId = _open();
    uint256[] memory payouts = _payouts(10_000_000, 0);
    _market.resolve(payouts, false);

    vm.prank(_KEEPER);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.SettlementNotFinal.selector, _yesId)
    );
    _controller.settle(positionId);
    _assertActive(positionId);
  }

  /// @notice Rejects a frozen record whose authoritative market has not reached terminal status.
  function test_nonterminalMarketStatusRejectsFrozenRecord() external {
    uint256 positionId = _open();
    _setSettlement(10_000_000, 0, false, 0, address(_pool), 1);

    vm.prank(_KEEPER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidMarketStatus.selector,
        address(_market),
        uint8(LibDreamMarginConstants.MARKET_STATUS_TRADING),
        uint8(LibDreamMarginConstants.MARKET_STATUS_RESOLVED)
      )
    );
    _controller.settle(positionId);
    _assertActive(positionId);
  }

  /// @notice Rejects a settlement record that is not bound to the position's pool and nonce.
  function test_wrongFrozenGenerationRevertsAtomically() external {
    uint256 positionId = _open();
    uint256[] memory payouts = _payouts(10_000_000, 0);
    _market.resolve(payouts, false);
    _setSettlement(10_000_000, 0, false, 0, address(0xBAD), 2);

    vm.prank(_KEEPER);
    vm.expectPartialRevert(LibDreamMarginErrors.IntegrationValueMismatch.selector);
    _controller.settle(positionId);
    _assertActive(positionId);
  }

  /// @notice Uses the frozen record after the recyclable pool has moved to another generation.
  function test_poolRecycleAfterFinalizationDoesNotStrandRedemption() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    IDreamDexBinaryPool.BinaryPoolInfo memory recycled = _poolInfo();
    recycled.marketNonce = 2;
    recycled.yesId = _yesId + 256;
    recycled.noId = _noId + 256;
    recycled.finalized = false;
    _pool.recycle(recycled, (_EXPIRY + 1 days) * 1e9);

    vm.prank(_KEEPER);
    _controller.settle(positionId);

    _assertClosed(positionId);
  }

  /// @notice Rolls back status, custody, and debt when DreamDEX redemption reverts.
  function test_redemptionRevertRollsBackEverything() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    _settlement.setBehavior(true, false, 0, false, 0);

    vm.prank(_KEEPER);
    vm.expectRevert();
    _controller.settle(positionId);

    _assertActive(positionId);
    assertEq(_settlementBacking(), 500 * _ONE);
  }

  /// @notice Rejects a truthful return paired with a dishonest collateral balance delta.
  function test_dishonestSettlementTransferRollsBackEverything() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    _settlement.setBehavior(false, true, 39 * _ONE, false, 0);

    vm.prank(_KEEPER);
    vm.expectPartialRevert(LibDreamMarginErrors.BalanceDeltaMismatch.selector);
    _controller.settle(positionId);

    _assertActive(positionId);
    assertEq(_settlementBacking(), 500 * _ONE);
  }

  /// @notice Rejects a dishonest return even when the actual collateral transfer is correct.
  function test_dishonestSettlementReturnRollsBackEverything() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    _settlement.setBehavior(false, false, 0, true, 41 * _ONE);

    vm.prank(_KEEPER);
    vm.expectPartialRevert(LibDreamMarginErrors.BalanceDeltaMismatch.selector);
    _controller.settle(positionId);

    _assertActive(positionId);
    assertEq(_settlementBacking(), 500 * _ONE);
  }

  /// @notice Rejects a callback settlement attempt while allowing the outer redemption to finish.
  function test_redemptionCallbackCannotReenterSettlement() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    _settlement.configureCallback(
      address(_controller), abi.encodeCall(IDreamMarginController.settle, (positionId))
    );

    vm.prank(_KEEPER);
    _controller.settle(positionId);

    assertFalse(_settlement.lastCallbackSucceeded());
    assertEq(bytes4(_settlement.lastCallbackData()), ReentrancyGuardTransient.Reentrancy.selector);
    _assertClosed(positionId);
  }

  /// @notice Revalidates terminal status after redemption and rolls back a mid-call status race.
  function test_statusRaceDuringRedemptionRollsBackEverything() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);
    _settlement.configureCallback(
      address(_market),
      abi.encodeCall(
        MockDreamDexBinaryMarket.setStatus, (LibDreamMarginConstants.MARKET_STATUS_TRADING)
      )
    );

    vm.prank(_KEEPER);
    vm.expectPartialRevert(LibDreamMarginErrors.InvalidMarketStatus.selector);
    _controller.settle(positionId);

    assertEq(_market.status(), LibDreamMarginConstants.MARKET_STATUS_RESOLVED);
    _assertActive(positionId);
    assertEq(_settlementBacking(), 500 * _ONE);
  }

  /// @notice Revokes the unavoidable broad settlement operator grant before returning.
  function test_settlementOperatorGrantIsTransactionScoped() external {
    uint256 positionId = _open();
    _finalize(10_000_000, 0, false, 0);

    vm.prank(_KEEPER);
    _controller.settle(positionId);

    assertFalse(_outcome.isOperator(address(_controller), address(_settlement)));
  }

  /// @notice A second terminal call cannot redeem, recognize loss, or mutate vault accounting.
  function test_repeatedSettlementIsIdempotentlyRejected() external {
    uint256 positionId = _open();
    _finalize(0, 10_000_000, false, 0);
    vm.prank(_KEEPER);
    _controller.settle(positionId);
    uint256 lossBefore = _vault.realizedBadDebt();
    uint256 backingBefore = _settlementBacking();

    vm.prank(_KEEPER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidPositionStatus.selector,
        positionId,
        uint8(PositionStatus.CLOSED),
        uint8(PositionStatus.ACTIVE)
      )
    );
    _controller.settle(positionId);

    assertEq(_vault.realizedBadDebt(), lossBefore);
    assertEq(_settlementBacking(), backingBefore);
    _assertClosed(positionId);
  }

  /// @notice Records later recovery only after exact new collateral reaches the vault.
  function test_laterRecoveryAddsCashWithoutResurrectingDebt() external {
    uint256 positionId = _open();
    _finalize(0, 10_000_000, false, 0);
    vm.prank(_KEEPER);
    _controller.settle(positionId);
    uint256 cashBefore = _vault.internalCash();

    vm.prank(_FUNDER);
    _controller.recordRecovery(4 * _ONE);

    assertEq(_vault.internalCash(), cashBefore + 4 * _ONE);
    assertEq(_vault.recoveredBadDebt(), 4 * _ONE);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_vault.totalDebtShares(), 0);

    vm.prank(_FUNDER);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.RecoveryExceedsLoss.selector, 6 * _ONE, 7 * _ONE)
    );
    _controller.recordRecovery(7 * _ONE);
  }

  /// @notice Direct facet calls cannot reach lifecycle state held by the controller.
  function test_directFacetCallCannotReachLifecycleState() external {
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.PositionNotFound.selector, 1));
    _positionSettlement.settle(1);
  }

  /// @notice Opens the canonical 2x position with forty outcomes and ten collateral debt.
  /// @return positionId Newly opened position.
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

  /// @notice Resolves the market and freezes the matching settlement record.
  /// @param yesPayout Fee-scaled YES numerator.
  /// @param noPayout Fee-scaled NO numerator.
  /// @param voided Whether the terminal result is a void.
  /// @param feeTimes1k One-time settlement fee retained for audit.
  function _finalize(uint256 yesPayout, uint256 noPayout, bool voided, uint256 feeTimes1k) private {
    _market.resolve(_payouts(yesPayout, noPayout), voided);
    _setSettlement(yesPayout, noPayout, voided, feeTimes1k, address(_pool), 1);
  }

  /// @notice Stores one frozen record with configurable binding fields.
  function _setSettlement(
    uint256 yesPayout,
    uint256 noPayout,
    bool voided,
    uint256 feeTimes1k,
    address pool,
    uint64 nonce
  ) private {
    _settlement.setSettlement(
      _yesId >> 8,
      IDreamDexBinarySettlement.SettlementRecord({
        collateralToken: address(_collateral),
        backing: uint128(500 * _ONE),
        finalized: true,
        voided: voided,
        settlementFeeBpsTimes1k: feeTimes1k,
        feeRecipient: address(0xFEE),
        pool: pool,
        nonce: nonce,
        payoutNumerators: _payouts(yesPayout, noPayout)
      })
    );
  }

  /// @notice Returns a two-element payout vector.
  function _payouts(uint256 yesPayout, uint256 noPayout)
    private
    pure
    returns (uint256[] memory payouts)
  {
    payouts = new uint256[](2);
    payouts[0] = yesPayout;
    payouts[1] = noPayout;
  }

  /// @notice Returns the frozen record's current backing.
  function _settlementBacking() private view returns (uint256 backing) {
    backing = _settlement.getSettlement(_yesId >> 8).backing;
  }

  /// @notice Asserts terminal zero state across position, controller, custody, and vault.
  /// @param positionId Position checked.
  function _assertClosed(uint256 positionId) private view {
    Position memory position = _controller.getPosition(positionId);
    assertEq(position.shares, 0);
    assertEq(position.debtShares, 0);
    assertEq(uint8(position.status), uint8(PositionStatus.CLOSED));
    _assertAggregates(0, 0);
  }

  /// @notice Asserts the canonical live position remains unchanged after a failed terminal call.
  /// @param positionId Position checked.
  function _assertActive(uint256 positionId) private view {
    Position memory position = _controller.getPosition(positionId);
    assertEq(position.shares, 40 * _ONE);
    assertEq(position.debtShares, 10 * _ONE);
    assertEq(uint8(position.status), uint8(PositionStatus.ACTIVE));
    _assertAggregates(40 * _ONE, 10 * _ONE);
  }

  /// @notice Asserts exact custody and every debt-attribution bucket.
  /// @param expectedShares Expected attributed shares.
  /// @param expectedDebtShares Expected attributed debt shares.
  function _assertAggregates(uint256 expectedShares, uint256 expectedDebtShares) private view {
    (
      uint256 attributedShares,
      uint256 outcomeDebtShares,
      uint256 marketDebtShares,
      uint256 totalDebtShares
    ) = _controller.aggregateState(_generationKey, _MARKET_GROUP, address(_outcome), _yesId);
    assertEq(attributedShares, expectedShares);
    assertEq(outcomeDebtShares, expectedDebtShares);
    assertEq(marketDebtShares, expectedDebtShares);
    assertEq(totalDebtShares, expectedDebtShares);
    assertEq(_outcome.balanceOf(address(_controller), _yesId), expectedShares);
    assertEq(_vault.totalDebtShares(), expectedDebtShares);
  }

  /// @notice Funds vault cash, pool execution, terminal backing, and caller accounts.
  function _fundAccounts() private {
    _collateral.mint(_LP, 1_000 * _ONE);
    vm.startPrank(_LP);
    _collateral.approve(address(_vault), type(uint256).max);
    _vault.deposit(1_000 * _ONE, _LP);
    vm.stopPrank();
    _collateral.mint(_OWNER, 100 * _ONE);
    _collateral.mint(_FUNDER, 100 * _ONE);
    _collateral.mint(address(_pool), 500 * _ONE);
    _collateral.mint(address(_settlement), 500 * _ONE);
    _outcome.mint(_OWNER, _yesId, 100 * _ONE);
    _outcome.mint(address(_pool), _yesId, 500 * _ONE);
  }

  /// @notice Returns separated initial administrative roles.
  function _initialRoles() private pure returns (DreamMarginController.InitialRoles memory roles) {
    roles = DreamMarginController.InitialRoles({
      governance: _GOVERNANCE,
      riskSteward: _RISK_STEWARD,
      guardian: _GUARDIAN,
      feeCollector: _FEE_COLLECTOR
    });
  }

  /// @notice Returns global debt, loss-window, utilization, and delay bounds.
  function _globalRisk() private pure returns (GlobalRiskConfig memory config) {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * _ONE,
      maxDailyRealizedLoss: 15 * _ONE,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: _DELAY,
      lossWindow: 1 days,
      lossCooldown: 2 days
    });
  }

  /// @notice Returns the exact-generation policy used by settlement tests.
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

  /// @notice Returns the observation policy used to admit positions before resolution.
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

  /// @notice Sets one deep uncrossed fifty-cent binary book.
  function _setBook() private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: 500_000, quantity: 500 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 600_000, quantity: 500 * _ONE});
    _pool.setBookLevels(true, bids);
    _pool.setBookLevels(false, asks);
  }

  /// @notice Returns the module record for the exact generation.
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
      yesId: _yesId,
      noId: _noId,
      tradingStart: 900_000,
      expiry: _EXPIRY
    });
  }

  /// @notice Returns the initial recyclable pool binding.
  function _poolInfo() private view returns (IDreamDexBinaryPool.BinaryPoolInfo memory info) {
    info = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(_collateral),
      market: address(_market),
      outcomeToken: address(_outcome),
      yesId: _yesId,
      noId: _noId,
      oneCollateral: _ONE,
      setBacking: _ONE,
      feeRecipient: address(0xFEE),
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: address(_settlement),
      marketNonce: 1,
      finalized: false
    });
  }

  /// @notice Encodes a DreamDEX ERC-6909 ID as pool, nonce, and low-byte outcome index.
  function _outcomeId(address pool, uint64 nonce, uint8 outcomeIndex)
    private
    pure
    returns (uint256 id)
  {
    id = (uint256(uint160(pool)) << 72) | (uint256(nonce) << 8) | outcomeIndex;
  }

  /// @notice Derives one full DreamMargin generation identity.
  function _deriveKey(MarketKey memory key) private pure returns (bytes32 generationKey) {
    generationKey = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
  }
}

// forge-lint: disable-end(unsafe-typecast, unused-return)
