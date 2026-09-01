// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin terminal position settlement
/// @author DreamMargin contributors
/// @notice Redeems frozen DreamDEX outcomes, settles debt first, and realizes bounded loss once.
/// @dev The immutable facet executes in controller storage and grants the settlement singleton
///      ERC-6909 operator authority only for the duration of one guarded redemption.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IDreamDexBinarySettlement} from "src/interfaces/integrations/IDreamDexBinarySettlement.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  MarketKey,
  Position,
  PositionStatus,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Immutable terminal-lifecycle facet reached through explicit controller wrappers.
contract PositionSettlement is DreamDexAdapter {
  using SafeTransferLib for address;

  /// @notice Prevents callbacks from crossing any controller lifecycle transition.
  modifier nonReentrantPositionSettlement() {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    uint8 status = self.reentrancyStatus;
    if (status != LibDreamMarginConstants.REENTRANCY_UNLOCKED) {
      revert LibDreamMarginErrors.ReentrantCall(status);
    }
    self.reentrancyStatus = LibDreamMarginConstants.REENTRANCY_LOCKED;
    _;
    self.reentrancyStatus = LibDreamMarginConstants.REENTRANCY_UNLOCKED;
  }

  /// @notice Redeems one frozen outcome and closes its position after debt-first allocation.
  /// @param positionId Position settled permissionlessly.
  /// @return repaid Actual terminal collateral received by the vault.
  /// @return ownerAssets Genuine collateral surplus returned to the position owner.
  /// @return badDebt Net loss remaining after actual recovery and funded reserve use.
  function settle(uint256 positionId)
    external
    nonReentrantPositionSettlement
    returns (uint256 repaid, uint256 ownerAssets, uint256 badDebt)
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, positionId);
    MarketKey memory key = _marketKey(position);
    bytes32 generationKey = LibDreamMarginStorage.generationKey(key);
    GenerationConfig storage config = self.generations[generationKey];
    ValidatedSettlement memory terminal =
      _validateSettlement(_moduleAddress(), key, position.outcomeIndex);
    position.status = PositionStatus.RESOLVED;

    uint256 redeemed = _redeem(position, key, terminal);
    uint256 shares = position.shares;
    position.shares = 0;
    self.attributedShares[position.outcomeToken][position.outcomeId] -= shares;

    uint256 debtShares = position.debtShares;
    if (debtShares != 0) {
      if (self.lossRecognized[positionId]) {
        revert LibDreamMarginErrors.LossAlreadyRecognized(positionId);
      }
      self.lossRecognized[positionId] = true;
      uint256 writtenOff;
      uint256 reserveUsed;
      (repaid, writtenOff, reserveUsed) = _settleVaultDebt(debtShares, redeemed);
      ownerAssets = redeemed - repaid;
      badDebt = writtenOff - reserveUsed;
      _removeDebtAttribution(self, position, config, generationKey, debtShares);
      _recordLoss(self, badDebt);
    } else {
      ownerAssets = redeemed;
    }

    position.status = PositionStatus.CLOSED;
    if (ownerAssets != 0) _sendAsset(_vault().asset(), position.owner, ownerAssets);
    // The controller lock remains held through the terminal transfer and canonical logs.
    // forge-lint: disable-start(reentrancy-events)
    emit IDreamMarginController.PositionSettled(positionId, repaid, ownerAssets, badDebt);
    emit IDreamMarginController.PositionClosed(positionId, position.owner, ownerAssets, 0);
    // forge-lint: disable-end(reentrancy-events)
  }

  /// @notice Supplies actual collateral to the vault's non-redeemable first-loss reserve.
  /// @param assets Exact collateral pulled from the caller.
  /// @return reserveShares Non-redeemable reserve shares minted by the vault.
  function fundReserve(uint256 assets)
    external
    nonReentrantPositionSettlement
    returns (uint256 reserveShares)
  {
    if (assets == 0) revert LibDreamMarginErrors.ZeroAmount(assets);
    IDreamMarginVault vault_ = _vault();
    address asset = vault_.asset();
    _pullAsset(asset, msg.sender, assets);
    asset.safeApproveWithRetry(address(vault_), assets);
    reserveShares = vault_.fundReserve(assets);
    asset.safeApproveWithRetry(address(vault_), 0);
    // The shared controller lock remains held through reserve funding and this log.
    // forge-lint: disable-next-line(reentrancy-events)
    emit IDreamMarginController.ReserveFunded(msg.sender, assets, reserveShares);
  }

  /// @notice Supplies actual collateral against cumulative bad debt without restoring receivables.
  /// @param assets Exact collateral pulled from the caller.
  function recordRecovery(uint256 assets) external nonReentrantPositionSettlement {
    if (assets == 0) revert LibDreamMarginErrors.ZeroAmount(assets);
    IDreamMarginVault vault_ = _vault();
    uint256 realized = vault_.realizedBadDebt();
    uint256 recovered = vault_.recoveredBadDebt();
    uint256 available = realized > recovered ? realized - recovered : 0;
    if (assets > available) {
      revert LibDreamMarginErrors.RecoveryExceedsLoss(available, assets);
    }

    address asset = vault_.asset();
    _pullAsset(asset, msg.sender, assets);
    asset.safeApproveWithRetry(address(vault_), assets);
    vault_.recordRecovery(assets);
    asset.safeApproveWithRetry(address(vault_), 0);
    // The shared controller lock remains held through recovery funding and this log.
    // forge-lint: disable-next-line(reentrancy-events)
    emit IDreamMarginController.BadDebtRecovered(msg.sender, assets);
  }

  /// @notice Burns exact attributed outcomes through the frozen singleton and reconciles both legs.
  /// @param position Position whose complete attributed balance is redeemed.
  /// @param key Exact generation tuple.
  /// @param terminal Validated pre-redemption settlement record.
  /// @return collateralOut Actual collateral received by the controller.
  function _redeem(
    Position storage position,
    MarketKey memory key,
    ValidatedSettlement memory terminal
  ) private returns (uint256 collateralOut) {
    uint256 shares = position.shares;
    uint256 expected = FixedPointMathLib.fullMulDiv(
      shares, terminal.payoutNumerator, LibDreamMarginConstants.SETTLEMENT_PAYOUT_DENOMINATOR
    );
    if (expected > terminal.backing) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "SETTLEMENT_BACKING", bytes32(expected), bytes32(terminal.backing)
      );
    }

    IERC6909 outcome = IERC6909(position.outcomeToken);
    IDreamDexBinarySettlement settlement = IDreamDexBinarySettlement(terminal.settlement);
    uint256 outcomeBefore = outcome.balanceOf(address(this), position.outcomeId);
    uint256 collateralBefore = IERC20Minimal(key.collateral).balanceOf(address(this));
    if (!outcome.setOperator(terminal.settlement, true)) {
      revert LibDreamMarginErrors.TokenOperatorApprovalFailed(
        position.outcomeToken, terminal.settlement, true
      );
    }
    if (!outcome.isOperator(address(this), terminal.settlement)) {
      revert LibDreamMarginErrors.TokenOperatorApprovalFailed(
        position.outcomeToken, terminal.settlement, true
      );
    }
    uint256 reported = settlement.redeem(position.outcomeId, shares, address(this));
    if (!outcome.setOperator(terminal.settlement, false)) {
      revert LibDreamMarginErrors.TokenOperatorApprovalFailed(
        position.outcomeToken, terminal.settlement, false
      );
    }
    if (outcome.isOperator(address(this), terminal.settlement)) {
      revert LibDreamMarginErrors.TokenOperatorApprovalFailed(
        position.outcomeToken, terminal.settlement, false
      );
    }

    uint256 outcomeAfter = outcome.balanceOf(address(this), position.outcomeId);
    uint256 collateralAfter = IERC20Minimal(key.collateral).balanceOf(address(this));
    if (outcomeAfter > outcomeBefore || outcomeBefore - outcomeAfter != shares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        position.outcomeToken, outcomeBefore - shares, outcomeAfter
      );
    }
    if (collateralAfter < collateralBefore) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        key.collateral, collateralBefore + expected, collateralAfter
      );
    }
    collateralOut = collateralAfter - collateralBefore;
    if (reported != expected || collateralOut != expected) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(key.collateral, expected, collateralOut);
    }

    ValidatedSettlement memory afterTerminal =
      _validateSettlement(_moduleAddress(), key, position.outcomeIndex);
    uint256 expectedBacking = terminal.backing - expected;
    if (
      afterTerminal.market != terminal.market || afterTerminal.settlement != terminal.settlement
        || afterTerminal.marketKey != terminal.marketKey
        || afterTerminal.payoutNumerator != terminal.payoutNumerator
        || afterTerminal.backing != expectedBacking
    ) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "SETTLEMENT_POST_STATE", bytes32(expectedBacking), bytes32(afterTerminal.backing)
      );
    }
  }

  /// @notice Sends terminal recovery to the vault and atomically retires all position debt shares.
  /// @param debtShares Exact position debt shares removed.
  /// @param availableRecovery Total actual redemption proceeds available.
  /// @return repaid Actual recovery pulled by the vault.
  /// @return writtenOff Unrecovered receivable removed.
  /// @return reserveUsed Funded reserve applied to the shortfall.
  function _settleVaultDebt(uint256 debtShares, uint256 availableRecovery)
    private
    returns (uint256 repaid, uint256 writtenOff, uint256 reserveUsed)
  {
    IDreamMarginVault vault_ = _vault();
    address asset = vault_.asset();
    if (availableRecovery != 0) {
      asset.safeApproveWithRetry(address(vault_), availableRecovery);
    }
    (repaid, writtenOff, reserveUsed) = vault_.settleDebt(debtShares, availableRecovery);
    if (availableRecovery != 0) asset.safeApproveWithRetry(address(vault_), 0);
    if (repaid > availableRecovery || reserveUsed > writtenOff) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(address(vault_), availableRecovery, repaid);
    }
  }

  /// @notice Removes every debt-attribution bucket after the vault retires terminal shares.
  /// @param self Controller namespace.
  /// @param position Settled position.
  /// @param config Exact generation risk configuration.
  /// @param generationKey Exact generation identifier.
  /// @param debtShares Debt shares retired.
  function _removeDebtAttribution(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 debtShares
  ) private {
    position.debtShares = 0;
    self.outcomeDebtShares[generationKey] -= debtShares;
    self.marketDebtShares[config.marketGroup] -= debtShares;
    self.totalDebtShares -= debtShares;
  }

  /// @notice Advances the fixed loss bucket and permissionlessly enforces reduce-only mode.
  /// @param self Controller namespace.
  /// @param badDebt Net loss remaining after funded reserve use.
  function _recordLoss(LibDreamMarginStorage.State storage self, uint256 badDebt) private {
    if (badDebt == 0) return;
    uint40 timestamp = _timestamp40();
    uint40 startedAt = self.lossWindowStartedAt;
    // The loss window is intentionally anchored to consensus time.
    // forge-lint: disable-next-line(block-timestamp)
    if (startedAt == 0 || block.timestamp >= uint256(startedAt) + self.globalRisk.lossWindow) {
      self.lossWindowStartedAt = timestamp;
      self.dailyRealizedLoss = badDebt;
    } else {
      self.dailyRealizedLoss += badDebt;
    }
    if (self.dailyRealizedLoss < self.globalRisk.maxDailyRealizedLoss) return;

    self.reduceOnlyTriggeredAt = timestamp;
    if (self.mode == ProtocolMode.ACTIVE) {
      self.mode = ProtocolMode.REDUCE_ONLY;
      emit IDreamMarginController.ProtocolModeUpdated(
        ProtocolMode.ACTIVE, ProtocolMode.REDUCE_ONLY, msg.sender
      );
    }
  }

  /// @notice Returns an existing active position, including a debt-free terminal holding.
  /// @param self Controller namespace.
  /// @param positionId Position identifier.
  /// @return position Active position storage reference.
  function _activePosition(LibDreamMarginStorage.State storage self, uint256 positionId)
    private
    view
    returns (Position storage position)
  {
    position = self.positions[positionId];
    if (position.owner == address(0)) revert LibDreamMarginErrors.PositionNotFound(positionId);
    if (position.status != PositionStatus.ACTIVE) {
      revert LibDreamMarginErrors.InvalidPositionStatus(
        positionId, uint8(position.status), uint8(PositionStatus.ACTIVE)
      );
    }
    if (position.shares == 0) {
      revert LibDreamMarginErrors.IncompleteClose(position.shares, position.debtShares);
    }
  }

  /// @notice Reconstructs the exact generation tuple stored in a position.
  /// @param position Position source.
  /// @return key Full pinned generation tuple.
  function _marketKey(Position storage position) private view returns (MarketKey memory key) {
    key = MarketKey({
      marketId: position.marketId,
      pool: position.pool,
      marketNonce: position.marketNonce,
      outcomeToken: position.outcomeToken,
      outcomeId: position.outcomeId,
      collateral: _vault().asset()
    });
  }

  /// @notice Pulls exact collateral from the current caller and rejects taxed transfers.
  /// @param asset Collateral token.
  /// @param payer Account supplying assets.
  /// @param amount Exact amount required.
  function _pullAsset(address asset, address payer, uint256 amount) private {
    uint256 beforeBalance = IERC20Minimal(asset).balanceOf(address(this));
    // Reserve and recovery funding intentionally pull only from the consenting caller.
    // forge-lint: disable-next-line(arbitrary-send-erc20)
    asset.safeTransferFrom(payer, address(this), amount);
    uint256 afterBalance = IERC20Minimal(asset).balanceOf(address(this));
    if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(asset, beforeBalance + amount, afterBalance);
    }
  }

  /// @notice Sends exact terminal surplus from controller custody.
  /// @param asset Collateral token.
  /// @param receiver Position owner.
  /// @param amount Exact amount sent.
  function _sendAsset(address asset, address receiver, uint256 amount) private {
    uint256 beforeBalance = IERC20Minimal(asset).balanceOf(address(this));
    asset.safeTransfer(receiver, amount);
    uint256 afterBalance = IERC20Minimal(asset).balanceOf(address(this));
    if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(asset, beforeBalance - amount, afterBalance);
    }
  }

  /// @notice Returns the executing controller's immutable module.
  /// @return module_ Bound DreamDEX module.
  function _moduleAddress() private view returns (address module_) {
    module_ = IDreamMarginController(address(this)).module();
  }

  /// @notice Returns the executing controller's immutable vault.
  /// @return vault_ Bound collateral vault.
  function _vault() private view returns (IDreamMarginVault vault_) {
    vault_ = IDreamMarginVault(IDreamMarginController(address(this)).vault());
  }

  /// @notice Converts the current timestamp to the storage width without truncation.
  /// @return timestamp Current timestamp as uint40.
  function _timestamp40() private view returns (uint40 timestamp) {
    // Consensus time is the loss-window and cooldown clock being bounded here.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > type(uint40).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("TIMESTAMP", block.timestamp, type(uint40).max);
    }
    // The preceding bound proves this storage-width conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    timestamp = uint40(block.timestamp);
  }
}
