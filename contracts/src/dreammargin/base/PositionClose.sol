// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position reduction and close
/// @author DreamMargin contributors
/// @notice Repays debt, safely withdraws outcomes, deleverages, and closes positions debt-first.
/// @dev The immutable facet executes through the controller and declares no persistent state.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {DreamMarginReentrancyGuard} from "src/libs/dreammargin/DreamMarginReentrancyGuard.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  MarketKey,
  Position,
  PositionStatus
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibPositionRisk, PositionHealth} from "src/libs/dreammargin/LibPositionRisk.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Immutable ordinary-reduction facet reached through explicit controller wrappers.
contract PositionClose is DreamDexAdapter, DreamMarginReentrancyGuard {
  using SafeTransferLib for address;

  /// @notice Repays up to a bounded amount for any active position in every protocol mode.
  /// @param positionId Position whose debt decreases.
  /// @param maxAssets Maximum collateral pulled from the payer.
  /// @return assetsRepaid Collateral actually received by the vault.
  function repay(uint256 positionId, uint256 maxAssets)
    external
    nonReentrant
    returns (uint256 assetsRepaid)
  {
    if (maxAssets == 0) revert LibDreamMarginErrors.ZeroAmount(maxAssets);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, positionId);
    bytes32 generationKey = _generationKey(position);
    GenerationConfig storage config = self.generations[generationKey];
    uint256 sharesRepaid;
    (assetsRepaid, sharesRepaid) =
      _repayFrom(self, position, config, generationKey, msg.sender, maxAssets, position.debtShares);
    // The shared controller lock remains held through repayment and this log.
    // forge-lint: disable-next-line(reentrancy-events)
    emit IDreamMarginController.PositionRepaid(positionId, msg.sender, assetsRepaid, sharesRepaid);
  }

  /// @notice Withdraws debt-free or conservatively excess outcome collateral to its owner.
  /// @param positionId Position whose attributed shares decrease.
  /// @param shares Exact shares transferred to the owner.
  function withdrawCollateral(uint256 positionId, uint256 shares) external nonReentrant {
    if (shares == 0) revert LibDreamMarginErrors.ZeroAmount(shares);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, positionId);
    _requireOwner(position, positionId);
    if (shares > position.shares) {
      revert LibDreamMarginErrors.InsufficientPositionShares(position.shares, shares);
    }
    uint256 remainingShares = uint256(position.shares) - shares;
    if (position.debtShares != 0) _requireWithdrawalHealth(self, position, remainingShares);

    position.shares = _uint128("POSITION_SHARES", remainingShares);
    self.attributedShares[position.outcomeToken][position.outcomeId] -= shares;
    if (remainingShares == 0) position.status = PositionStatus.CLOSED;
    _sendOutcome(position.outcomeToken, position.outcomeId, position.owner, shares);
    // The shared controller lock remains held through transfer and both logs.
    // forge-lint: disable-next-line(reentrancy-events)
    emit IDreamMarginController.CollateralWithdrawn(positionId, position.owner, shares);
    if (remainingShares == 0) {
      // forge-lint: disable-next-line(reentrancy-events)
      emit IDreamMarginController.PositionClosed(positionId, position.owner, 0, shares);
    }
  }

  /// @notice Sells bounded outcome shares and applies actual proceeds to debt before owner value.
  /// @param params Position, quantity, price, fill, and deadline bounds.
  /// @return sharesSold Actual outcome shares removed by DreamDEX.
  /// @return assetsRepaid Actual collateral received by the vault.
  function deleverage(IDreamMarginController.DeleverageParams calldata params)
    external
    nonReentrant
    returns (uint256 sharesSold, uint256 assetsRepaid)
  {
    if (params.sharesToSell == 0) {
      revert LibDreamMarginErrors.ZeroAmount(params.sharesToSell);
    }
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, params.positionId);
    _requireOwner(position, params.positionId);
    if (params.sharesToSell > position.shares) {
      revert LibDreamMarginErrors.InsufficientPositionShares(position.shares, params.sharesToSell);
    }

    ExecutionResult memory execution = _sellOutcome(
      _moduleAddress(),
      ImmediateOrder({
        key: _marketKey(position),
        outcomeIndex: position.outcomeIndex,
        price: params.limitPrice,
        quantity: params.sharesToSell,
        minimumOutput: params.minCollateralOut,
        maximumInput: 0,
        deadline: params.deadline,
        orderType: params.orderType,
        userData: _positionUserData(params.positionId)
      })
    );
    sharesSold = execution.outcomeAmount;
    uint256 oldShares = position.shares;
    uint256 oldDebtShares = position.debtShares;
    uint256 remainingShares = oldShares - sharesSold;
    bytes32 generationKey = _generationKey(position);
    GenerationConfig storage config = self.generations[generationKey];
    uint256 ownerAssets;
    (assetsRepaid, ownerAssets) =
      _applyProceeds(self, position, config, generationKey, execution.collateralAmount);
    _requireNonWorseningReduction(
      config, oldShares, oldDebtShares, remainingShares, position.debtShares
    );

    position.shares = _uint128("POSITION_SHARES", remainingShares);
    self.attributedShares[position.outcomeToken][position.outcomeId] -= sharesSold;
    if (remainingShares == 0 && position.debtShares == 0) {
      position.status = PositionStatus.CLOSED;
    }
    if (ownerAssets != 0) _sendAsset(_vault().asset(), position.owner, ownerAssets);
    emit IDreamMarginController.PositionDeleveraged(params.positionId, sharesSold, assetsRepaid);
    if (position.status == PositionStatus.CLOSED) {
      emit IDreamMarginController.PositionClosed(params.positionId, position.owner, ownerAssets, 0);
    }
  }

  /// @notice Fully closes into collateral or externally repaid outcome shares.
  /// @param params Position, repayment, execution, and output choices.
  /// @return assetsOut Residual collateral returned after debt repayment.
  /// @return sharesOut Residual outcome shares returned after debt repayment.
  function close(IDreamMarginController.CloseParams calldata params)
    external
    nonReentrant
    returns (uint256 assetsOut, uint256 sharesOut)
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, params.positionId);
    _requireOwner(position, params.positionId);
    position.status = PositionStatus.CLOSING;
    bytes32 generationKey = _generationKey(position);
    GenerationConfig storage config = self.generations[generationKey];
    uint256 originalShares = position.shares;

    if (params.withdrawOutcome) {
      if (position.debtShares != 0) {
        _repayFrom(
          self,
          position,
          config,
          generationKey,
          msg.sender,
          params.maxRepayAssets,
          position.debtShares
        );
      }
      sharesOut = originalShares;
    } else {
      ExecutionResult memory execution = _sellOutcome(
        _moduleAddress(),
        ImmediateOrder({
          key: _marketKey(position),
          outcomeIndex: position.outcomeIndex,
          price: params.limitPrice,
          quantity: originalShares,
          minimumOutput: params.minCollateralOut,
          maximumInput: 0,
          deadline: params.deadline,
          orderType: params.orderType,
          userData: _positionUserData(params.positionId)
        })
      );
      if (execution.outcomeAmount != originalShares) {
        revert LibDreamMarginErrors.IncompleteClose(
          originalShares - execution.outcomeAmount, position.debtShares
        );
      }
      assetsOut = _repayCloseDebt(
        self, position, config, generationKey, execution.collateralAmount, params.maxRepayAssets
      );
    }

    if (position.debtShares != 0) {
      revert LibDreamMarginErrors.IncompleteClose(originalShares, position.debtShares);
    }
    position.shares = 0;
    position.status = PositionStatus.CLOSED;
    self.attributedShares[position.outcomeToken][position.outcomeId] -= originalShares;
    if (params.withdrawOutcome && originalShares != 0) {
      _sendOutcome(position.outcomeToken, position.outcomeId, position.owner, originalShares);
    }
    if (assetsOut != 0) _sendAsset(_vault().asset(), position.owner, assetsOut);
    // The shared controller lock remains held through all close transfers and this log.
    // forge-lint: disable-start(reentrancy-events)
    emit IDreamMarginController.PositionClosed(
      params.positionId, position.owner, assetsOut, sharesOut
    );
    // forge-lint: disable-end(reentrancy-events)
  }

  /// @notice Repays selected debt shares from one payer and updates all debt attribution.
  /// @param self Controller namespace.
  /// @param position Position whose debt decreases.
  /// @param config Exact generation policy containing market attribution and minimum debt.
  /// @param generationKey Exact generation identifier.
  /// @param payer Account supplying collateral.
  /// @param maxAssets Maximum collateral authorized.
  /// @param maxDebtShares Maximum position debt shares retired.
  /// @return assetsRepaid Actual assets received by the vault.
  /// @return sharesRepaid Actual debt shares retired.
  function _repayFrom(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    address payer,
    uint256 maxAssets,
    uint256 maxDebtShares
  ) private returns (uint256 assetsRepaid, uint256 sharesRepaid) {
    uint256 positionDebtShares = position.debtShares;
    if (positionDebtShares == 0) revert LibDreamMarginErrors.ZeroAmount(positionDebtShares);
    IDreamMarginVault vault_ = _vault();
    uint256 fullDebtAssets = vault_.debtAssets(positionDebtShares);
    uint256 repayShares = maxAssets >= fullDebtAssets
      ? positionDebtShares
      : LibPositionRisk.debtSharesDown(maxAssets, vault_.debtIndexWad());
    if (repayShares > maxDebtShares) repayShares = maxDebtShares;
    if (repayShares == 0) revert LibDreamMarginErrors.ZeroAmount(repayShares);
    uint256 assetsUpperBound = vault_.debtAssets(repayShares);
    if (assetsUpperBound > maxAssets) {
      revert LibDreamMarginErrors.RepaymentLimitExceeded(assetsUpperBound, maxAssets);
    }
    uint256 remainingDebtShares = positionDebtShares - repayShares;
    if (remainingDebtShares != 0) {
      uint256 remainingDebt = vault_.debtAssets(remainingDebtShares);
      if (remainingDebt < config.risk.minDebt) {
        revert LibDreamMarginErrors.DebtCapExceeded("MIN_DEBT", remainingDebt, config.risk.minDebt);
      }
    }

    address asset = vault_.asset();
    _pullAsset(asset, payer, assetsUpperBound);
    asset.safeApproveWithRetry(address(vault_), assetsUpperBound);
    (assetsRepaid, sharesRepaid) = vault_.repay(repayShares, assetsUpperBound);
    asset.safeApproveWithRetry(address(vault_), 0);
    if (sharesRepaid != repayShares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(address(vault_), repayShares, sharesRepaid);
    }
    uint256 refund = assetsUpperBound - assetsRepaid;
    if (refund != 0) _sendAsset(asset, payer, refund);
    position.debtShares = _uint128("POSITION_DEBT_SHARES", remainingDebtShares);
    self.outcomeDebtShares[generationKey] -= repayShares;
    self.marketDebtShares[config.marketGroup] -= repayShares;
    self.totalDebtShares -= repayShares;
  }

  /// @notice Applies sale proceeds to debt and withholds all owner value while debt remains.
  /// @param self Controller namespace.
  /// @param position Position being reduced.
  /// @param config Exact generation policy.
  /// @param generationKey Exact generation identifier.
  /// @param proceeds Actual collateral received from DreamDEX.
  /// @return assetsRepaid Assets applied to vault debt.
  /// @return ownerAssets Residual collateral releasable only after zero debt.
  function _applyProceeds(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 proceeds
  ) private returns (uint256 assetsRepaid, uint256 ownerAssets) {
    if (position.debtShares == 0) return (0, proceeds);
    IDreamMarginVault vault_ = _vault();
    uint256 repayShares = proceeds >= vault_.debtAssets(position.debtShares)
      ? position.debtShares
      : LibPositionRisk.debtSharesDown(proceeds, vault_.debtIndexWad());
    uint256 remaining = proceeds;
    if (repayShares != 0) {
      address asset = vault_.asset();
      asset.safeApproveWithRetry(address(vault_), proceeds);
      uint256 sharesRepaid;
      (assetsRepaid, sharesRepaid) = vault_.repay(repayShares, proceeds);
      asset.safeApproveWithRetry(address(vault_), 0);
      if (sharesRepaid != repayShares) {
        revert LibDreamMarginErrors.BalanceDeltaMismatch(address(vault_), repayShares, sharesRepaid);
      }
      remaining -= assetsRepaid;
      position.debtShares =
        _uint128("POSITION_DEBT_SHARES", uint256(position.debtShares) - repayShares);
      self.outcomeDebtShares[generationKey] -= repayShares;
      self.marketDebtShares[config.marketGroup] -= repayShares;
      self.totalDebtShares -= repayShares;
    }
    if (position.debtShares == 0) {
      ownerAssets = remaining;
    } else {
      uint256 remainingDebt = vault_.debtAssets(position.debtShares);
      if (remainingDebt < config.risk.minDebt) {
        revert LibDreamMarginErrors.DebtCapExceeded("MIN_DEBT", remainingDebt, config.risk.minDebt);
      }
      if (remaining != 0) {
        address asset = vault_.asset();
        asset.safeApproveWithRetry(address(vault_), remaining);
        // The reserve rejects quantized-zero funding and receives only unreleasable sale dust.
        // forge-lint: disable-next-line(unused-return)
        vault_.fundReserve(remaining);
        asset.safeApproveWithRetry(address(vault_), 0);
      }
    }
  }

  /// @notice Fully repays close debt from sale proceeds plus a bounded owner top-up.
  /// @param self Controller namespace.
  /// @param position Position reaching zero debt.
  /// @param config Exact generation policy.
  /// @param generationKey Exact generation identifier.
  /// @param proceeds Actual DreamDEX collateral proceeds.
  /// @param maxTopUp Maximum external owner collateral pulled.
  /// @return ownerAssets Residual sale collateral and any rounding refund.
  function _repayCloseDebt(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 proceeds,
    uint256 maxTopUp
  ) private returns (uint256 ownerAssets) {
    uint256 debtShares = position.debtShares;
    if (debtShares == 0) return proceeds;
    IDreamMarginVault vault_ = _vault();
    uint256 upperDebt = vault_.debtAssets(debtShares);
    uint256 topUp = upperDebt > proceeds ? upperDebt - proceeds : 0;
    if (topUp > maxTopUp) {
      revert LibDreamMarginErrors.RepaymentLimitExceeded(topUp, maxTopUp);
    }
    address asset = vault_.asset();
    if (topUp != 0) _pullAsset(asset, position.owner, topUp);
    uint256 available = proceeds + topUp;
    asset.safeApproveWithRetry(address(vault_), available);
    uint256 assetsRepaid;
    uint256 sharesRepaid;
    (assetsRepaid, sharesRepaid) = vault_.repay(debtShares, available);
    asset.safeApproveWithRetry(address(vault_), 0);
    if (sharesRepaid != debtShares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(address(vault_), debtShares, sharesRepaid);
    }
    ownerAssets = available - assetsRepaid;
    position.debtShares = 0;
    self.outcomeDebtShares[generationKey] -= debtShares;
    self.marketDebtShares[config.marketGroup] -= debtShares;
    self.totalDebtShares -= debtShares;
  }

  /// @notice Requires a partial deleverage not to increase debt shares per remaining outcome share.
  /// @param config Exact generation policy containing the minimum debt bound.
  /// @param oldShares Position shares before execution.
  /// @param oldDebtShares Position debt shares before repayment.
  /// @param remainingShares Position shares after actual execution.
  /// @param remainingDebtShares Position debt shares after actual repayment.
  function _requireNonWorseningReduction(
    GenerationConfig storage config,
    uint256 oldShares,
    uint256 oldDebtShares,
    uint256 remainingShares,
    uint256 remainingDebtShares
  ) private view {
    if (remainingDebtShares == 0) return;
    if (remainingShares == 0) {
      revert LibDreamMarginErrors.InsufficientHealth(0, remainingDebtShares);
    }
    uint256 normalizedDebt =
      FixedPointMathLib.fullMulDivUp(remainingDebtShares, oldShares, remainingShares);
    if (normalizedDebt > oldDebtShares) {
      revert LibDreamMarginErrors.InsufficientHealth(oldDebtShares, normalizedDebt);
    }
    uint256 remainingDebt = _vault().debtAssets(remainingDebtShares);
    if (remainingDebt < config.risk.minDebt) {
      revert LibDreamMarginErrors.DebtCapExceeded("MIN_DEBT", remainingDebt, config.risk.minDebt);
    }
  }

  /// @notice Requires remaining leveraged collateral to pass compressed initial health.
  /// @param self Controller namespace.
  /// @param position Position being withdrawn from.
  /// @param remainingShares Shares retained after the requested withdrawal.
  function _requireWithdrawalHealth(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    uint256 remainingShares
  ) private view {
    bytes32 generationKey = _generationKey(position);
    GenerationConfig storage config = self.generations[generationKey];
    ValidatedGeneration memory generation =
      _validateGeneration(_moduleAddress(), _marketKey(position), position.outcomeIndex, true);
    // The oracle itself rejects immature, stale, recycled, or terminal generation state.
    // forge-lint: disable-start(unused-return)
    (uint256 mark,,) = IDreamDexMarkOracle(_oracleAddress()).conservativeTwap(generationKey);
    // forge-lint: disable-end(unused-return)
    uint256 haircutMark = FixedPointMathLib.fullMulDiv(
      mark, config.risk.collateralFactorBps, LibDreamMarginConstants.BPS
    );
    uint256 grossValue =
      LibPositionRisk.collateralValueDown(remainingShares, haircutMark, generation.oneCollateral);
    uint256 debtAssets = _vault().debtAssets(position.debtShares);
    PositionHealth memory health = LibPositionRisk.positionHealth(grossValue, debtAssets);
    // Expiry compression is a deliberate risk boundary for collateral release.
    // forge-lint: disable-next-line(block-timestamp)
    uint256 timeToExpiry = position.expiry > block.timestamp ? position.expiry - block.timestamp : 0;
    uint256 maintenance = LibPositionRisk.maintenanceLtvBps(
      config.risk.maintenanceLtvBps, timeToExpiry, config.risk.compressionWindow
    );
    uint256 maximumLtv =
      maintenance < config.risk.initialLtvBps ? maintenance : config.risk.initialLtvBps;
    if (maximumLtv == 0 || health.ltvBps > maximumLtv) {
      uint256 requiredValue = maximumLtv == 0
        ? type(uint256).max
        : FixedPointMathLib.fullMulDivUp(debtAssets, LibDreamMarginConstants.BPS, maximumLtv);
      revert LibDreamMarginErrors.InsufficientHealth(grossValue, requiredValue);
    }
  }

  /// @notice Returns one existing active position.
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
  }

  /// @notice Requires the caller to be the recorded position owner.
  /// @param position Position accessed.
  /// @param positionId Position identifier.
  function _requireOwner(Position storage position, uint256 positionId) private view {
    if (position.owner != msg.sender) {
      revert LibDreamMarginErrors.NotPositionOwner(msg.sender, position.owner, positionId);
    }
  }

  /// @notice Reconstructs the full market key pinned in a position.
  /// @param position Position source.
  /// @return key Exact market generation tuple.
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

  /// @notice Derives the full generation key pinned in a position.
  /// @param position Position source.
  /// @return generationKey Exact generation identifier.
  function _generationKey(Position storage position) private view returns (bytes32 generationKey) {
    generationKey = LibDreamMarginStorage.generationKey(_marketKey(position));
  }

  /// @notice Pulls an exact collateral amount and rejects transfer-tax behavior.
  /// @param asset Collateral token.
  /// @param payer Account supplying assets.
  /// @param amount Exact amount required.
  function _pullAsset(address asset, address payer, uint256 amount) private {
    uint256 beforeBalance = IERC20Minimal(asset).balanceOf(address(this));
    // Repayment deliberately permits third-party payers; proceeds can only reduce recorded debt.
    // forge-lint: disable-next-line(arbitrary-send-erc20)
    asset.safeTransferFrom(payer, address(this), amount);
    uint256 afterBalance = IERC20Minimal(asset).balanceOf(address(this));
    if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(asset, beforeBalance + amount, afterBalance);
    }
  }

  /// @notice Sends exact collateral from the controller.
  /// @param asset Collateral token.
  /// @param receiver Recipient.
  /// @param amount Exact amount sent.
  function _sendAsset(address asset, address receiver, uint256 amount) private {
    uint256 beforeBalance = IERC20Minimal(asset).balanceOf(address(this));
    asset.safeTransfer(receiver, amount);
    uint256 afterBalance = IERC20Minimal(asset).balanceOf(address(this));
    if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(asset, beforeBalance - amount, afterBalance);
    }
  }

  /// @notice Sends one exact outcome ID from attributed controller custody.
  /// @param token ERC-6909 outcome token.
  /// @param outcomeId Exact outcome ID.
  /// @param receiver Position owner.
  /// @param shares Exact shares sent.
  function _sendOutcome(address token, uint256 outcomeId, address receiver, uint256 shares)
    private
  {
    IERC6909 outcome = IERC6909(token);
    uint256 beforeBalance = outcome.balanceOf(address(this), outcomeId);
    bool success = outcome.transfer(receiver, outcomeId, shares);
    uint256 afterBalance = outcome.balanceOf(address(this), outcomeId);
    if (!success || afterBalance > beforeBalance || beforeBalance - afterBalance != shares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(token, beforeBalance - shares, afterBalance);
    }
  }

  /// @notice Returns the executing controller's immutable module.
  /// @return module_ Bound DreamDEX module.
  function _moduleAddress() private view returns (address module_) {
    module_ = IDreamMarginController(address(this)).module();
  }

  /// @notice Returns the executing controller's immutable vault.
  /// @return vault_ Bound vault interface.
  function _vault() private view returns (IDreamMarginVault vault_) {
    vault_ = IDreamMarginVault(IDreamMarginController(address(this)).vault());
  }

  /// @notice Returns the executing controller's immutable oracle.
  /// @return oracle_ Bound oracle address.
  function _oracleAddress() private view returns (address oracle_) {
    oracle_ = IDreamMarginController(address(this)).oracle();
  }

  /// @notice Narrows one stored position field after an explicit bound check.
  /// @param field Field identifier.
  /// @param value Value narrowed.
  /// @return narrowed Checked 128-bit value.
  function _uint128(bytes32 field, uint256 value) private pure returns (uint128 narrowed) {
    if (value > type(uint128).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds(field, value, type(uint128).max);
    }
    // The preceding check proves the cast cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    narrowed = uint128(value);
  }

  /// @notice Encodes one checked position identifier in DreamDEX user data.
  /// @param positionId Position identifier.
  /// @return userData Checked 64-bit value.
  function _positionUserData(uint256 positionId) private pure returns (uint64 userData) {
    if (positionId > type(uint64).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("POSITION_ID", positionId, type(uint64).max);
    }
    // The preceding check proves the cast cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    userData = uint64(positionId);
  }
}
