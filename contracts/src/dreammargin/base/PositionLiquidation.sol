// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin permissionless position liquidation
/// @author DreamMargin contributors
/// @notice Liquidates unhealthy positions through collateral take or bounded direct sale.
/// @dev The immutable facet executes in controller storage and never creates a liquidation loan.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  MarketKey,
  Position,
  PositionStatus
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {
  LibPositionRisk,
  PositionHealth,
  RecoveryValue
} from "src/libs/dreammargin/LibPositionRisk.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Immutable liquidation facet reached through the controller's exact selector wrapper.
contract PositionLiquidation is DreamDexAdapter {
  using SafeTransferLib for address;

  /// @notice Values captured at the eligibility boundary before liquidation interactions.
  /// @param generationKey Exact registered generation identifier.
  /// @param debtAssets Current rounded-up debt.
  /// @param liquidationValue Size-aware executable value after the TWAP haircut cap.
  /// @param unitPrice Per-whole-outcome liquidation value rounded down.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @param maintenanceLtvBps Current expiry-compressed liquidation boundary.
  struct LiquidationSnapshot {
    bytes32 generationKey;
    uint256 debtAssets;
    uint256 liquidationValue;
    uint256 unitPrice;
    uint256 oneOutcome;
    uint256 maintenanceLtvBps;
  }

  /// @notice Prevents callbacks from crossing any controller lifecycle transition.
  modifier nonReentrantPositionLiquidation() {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    uint8 status = self.reentrancyStatus;
    if (status != LibDreamMarginConstants.REENTRANCY_UNLOCKED) {
      revert LibDreamMarginErrors.ReentrantCall(status);
    }
    self.reentrancyStatus = LibDreamMarginConstants.REENTRANCY_LOCKED;
    _;
    self.reentrancyStatus = LibDreamMarginConstants.REENTRANCY_UNLOCKED;
  }

  /// @notice Liquidates one unhealthy trading position through a caller-bounded route.
  /// @param params Position, payment, execution, output, deadline, and route bounds.
  /// @return repaid Collateral actually received by the vault.
  /// @return seized Outcome shares transferred or sold.
  /// @return incentive Genuine collateral surplus paid to the liquidator.
  function liquidate(IDreamMarginController.LiquidationParams calldata params)
    external
    nonReentrantPositionLiquidation
    returns (uint256 repaid, uint256 seized, uint256 incentive)
  {
    if (params.maxDebtAssets == 0) {
      revert LibDreamMarginErrors.ZeroAmount(params.maxDebtAssets);
    }
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = _activePosition(self, params.positionId);
    bytes32 generationKey = _generationKey(position);
    GenerationConfig storage config = self.generations[generationKey];
    LiquidationSnapshot memory snapshot =
      _requireLiquidatable(position, config, generationKey, params.positionId);
    position.status = PositionStatus.LIQUIDATING;

    uint256 ownerAssets = 0;
    if (params.route == IDreamMarginController.LiquidationRoute.COLLATERAL_TAKE) {
      (repaid, seized, incentive) = _takeCollateral(self, position, config, snapshot, params);
    } else {
      (repaid, seized, incentive, ownerAssets) =
        _sellCollateral(self, position, config, snapshot.generationKey, params);
    }

    _finalizePosition(position, config);
    if (ownerAssets != 0) _sendAsset(_vault().asset(), position.owner, ownerAssets);
    // All interactions remain covered by the shared controller lock through canonical logs.
    // forge-lint: disable-start(reentrancy-events)
    emit IDreamMarginController.PositionLiquidated(
      params.positionId, msg.sender, params.route, repaid, seized, incentive
    );
    if (position.status == PositionStatus.CLOSED) {
      emit IDreamMarginController.PositionClosed(params.positionId, position.owner, ownerAssets, 0);
    }
    // forge-lint: disable-end(reentrancy-events)
  }

  /// @notice Repays liquidator-funded debt and sends conservatively discounted exact-ID shares.
  /// @param self Controller namespace.
  /// @param position Position being liquidated.
  /// @param config Exact generation risk policy.
  /// @param snapshot Pre-interaction eligibility values.
  /// @param params Caller bounds.
  /// @return repaid Assets received by the vault.
  /// @return seized Exact outcome shares transferred to the liquidator.
  /// @return incentive Collateral-value bonus represented by seized shares.
  function _takeCollateral(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    LiquidationSnapshot memory snapshot,
    IDreamMarginController.LiquidationParams calldata params
  ) private returns (uint256 repaid, uint256 seized, uint256 incentive) {
    if (snapshot.unitPrice == 0) {
      revert LibDreamMarginErrors.InsufficientHealth(0, snapshot.debtAssets);
    }
    repaid =
      _repayFromLiquidator(self, position, config, snapshot.generationKey, params.maxDebtAssets);
    seized = LibPositionRisk.liquidationSharesUp(
      repaid,
      config.risk.liquidationBonusBps,
      snapshot.unitPrice,
      snapshot.oneOutcome,
      position.shares
    );
    if (seized < params.minSharesOut) {
      revert LibDreamMarginErrors.InsufficientSharesOut(seized, params.minSharesOut);
    }
    if (seized == 0) revert LibDreamMarginErrors.ZeroAmount(seized);

    position.shares = _uint128("POSITION_SHARES", uint256(position.shares) - seized);
    self.attributedShares[position.outcomeToken][position.outcomeId] -= seized;
    uint256 seizedValue =
      LibPositionRisk.collateralValueDown(seized, snapshot.unitPrice, snapshot.oneOutcome);
    uint256 representedBonus = seizedValue > repaid ? seizedValue - repaid : 0;
    uint256 maximumBonus = FixedPointMathLib.fullMulDiv(
      repaid, config.risk.liquidationBonusBps, LibDreamMarginConstants.BPS
    );
    incentive = representedBonus < maximumBonus ? representedBonus : maximumBonus;
    _sendOutcome(position.outcomeToken, position.outcomeId, msg.sender, seized);
  }

  /// @notice Sells attributed shares, applies actual proceeds debt-first, then splits true surplus.
  /// @param self Controller namespace.
  /// @param position Position being liquidated.
  /// @param config Exact generation risk policy.
  /// @param generationKey Exact registered generation identifier.
  /// @param params Caller bounds.
  /// @return repaid Assets received by the vault.
  /// @return seized Actual outcome shares sold.
  /// @return incentive Genuine collateral surplus paid to the liquidator.
  /// @return ownerAssets Genuine collateral surplus paid to the position owner.
  function _sellCollateral(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    IDreamMarginController.LiquidationParams calldata params
  ) private returns (uint256 repaid, uint256 seized, uint256 incentive, uint256 ownerAssets) {
    ExecutionResult memory execution = _sellOutcome(
      _moduleAddress(),
      ImmediateOrder({
        key: _marketKey(position),
        outcomeIndex: position.outcomeIndex,
        price: params.limitPrice,
        quantity: position.shares,
        minimumOutput: params.minCollateralOut,
        maximumInput: 0,
        deadline: params.deadline,
        orderType: params.orderType,
        userData: _positionUserData(params.positionId)
      })
    );
    seized = execution.outcomeAmount;
    uint256 residual;
    (repaid, residual) = _repayFromSale(
      self, position, config, generationKey, execution.collateralAmount, params.maxDebtAssets
    );
    position.shares = _uint128("POSITION_SHARES", uint256(position.shares) - seized);
    self.attributedShares[position.outcomeToken][position.outcomeId] -= seized;

    if (position.debtShares == 0) {
      uint256 maximumIncentive = FixedPointMathLib.fullMulDiv(
        repaid, config.risk.liquidationBonusBps, LibDreamMarginConstants.BPS
      );
      incentive = residual < maximumIncentive ? residual : maximumIncentive;
      ownerAssets = residual - incentive;
      if (incentive != 0) _sendAsset(_vault().asset(), msg.sender, incentive);
    } else if (residual != 0) {
      address asset = _vault().asset();
      asset.safeApproveWithRetry(address(_vault()), residual);
      // Quantization dust cannot be released ahead of outstanding debt.
      // forge-lint: disable-next-line(unused-return)
      _vault().fundReserve(residual);
      asset.safeApproveWithRetry(address(_vault()), 0);
    }
  }

  /// @notice Pulls bounded liquidator collateral and retires selected debt shares.
  /// @param self Controller namespace.
  /// @param position Position whose debt decreases.
  /// @param config Exact generation policy.
  /// @param generationKey Exact generation identifier.
  /// @param maxAssets Maximum liquidator collateral authorized.
  /// @return assetsRepaid Assets received by the vault.
  function _repayFromLiquidator(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 maxAssets
  ) private returns (uint256 assetsRepaid) {
    IDreamMarginVault vault_ = _vault();
    uint256 positionDebtShares = position.debtShares;
    uint256 fullDebt = vault_.debtAssets(positionDebtShares);
    uint256 requestedShares = maxAssets >= fullDebt
      ? positionDebtShares
      : LibPositionRisk.debtSharesDown(maxAssets, vault_.debtIndexWad());
    if (requestedShares == 0) revert LibDreamMarginErrors.ZeroAmount(requestedShares);
    uint256 assetsUpperBound = vault_.debtAssets(requestedShares);
    if (assetsUpperBound > maxAssets) {
      revert LibDreamMarginErrors.RepaymentLimitExceeded(assetsUpperBound, maxAssets);
    }

    address asset = vault_.asset();
    _pullAsset(asset, msg.sender, assetsUpperBound);
    asset.safeApproveWithRetry(address(vault_), assetsUpperBound);
    uint256 sharesRepaid;
    (assetsRepaid, sharesRepaid) = vault_.repay(requestedShares, assetsUpperBound);
    asset.safeApproveWithRetry(address(vault_), 0);
    if (sharesRepaid != requestedShares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        address(vault_), requestedShares, sharesRepaid
      );
    }
    uint256 refund = assetsUpperBound - assetsRepaid;
    if (refund != 0) _sendAsset(asset, msg.sender, refund);
    _reduceDebtAttribution(self, position, config, generationKey, sharesRepaid);
  }

  /// @notice Applies actual sale proceeds to bounded debt shares and returns unallocated proceeds.
  /// @param self Controller namespace.
  /// @param position Position whose debt decreases.
  /// @param config Exact generation policy.
  /// @param generationKey Exact generation identifier.
  /// @param proceeds Actual collateral received from DreamDEX.
  /// @param maxDebtAssets Maximum proceeds permitted to repay debt.
  /// @return assetsRepaid Assets received by the vault.
  /// @return residual Sale proceeds remaining after repayment.
  function _repayFromSale(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 proceeds,
    uint256 maxDebtAssets
  ) private returns (uint256 assetsRepaid, uint256 residual) {
    IDreamMarginVault vault_ = _vault();
    uint256 budget = proceeds < maxDebtAssets ? proceeds : maxDebtAssets;
    uint256 fullDebt = vault_.debtAssets(position.debtShares);
    uint256 requestedShares = budget >= fullDebt
      ? position.debtShares
      : LibPositionRisk.debtSharesDown(budget, vault_.debtIndexWad());
    if (requestedShares == 0) revert LibDreamMarginErrors.ZeroAmount(requestedShares);

    address asset = vault_.asset();
    asset.safeApproveWithRetry(address(vault_), proceeds);
    uint256 sharesRepaid;
    (assetsRepaid, sharesRepaid) = vault_.repay(requestedShares, proceeds);
    asset.safeApproveWithRetry(address(vault_), 0);
    if (sharesRepaid != requestedShares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        address(vault_), requestedShares, sharesRepaid
      );
    }
    if (assetsRepaid > maxDebtAssets) {
      revert LibDreamMarginErrors.RepaymentLimitExceeded(assetsRepaid, maxDebtAssets);
    }
    residual = proceeds - assetsRepaid;
    _reduceDebtAttribution(self, position, config, generationKey, sharesRepaid);
  }

  /// @notice Decrements position, generation, market, global, and vault debt attribution together.
  /// @param self Controller namespace.
  /// @param position Position whose debt decreases.
  /// @param config Exact generation policy.
  /// @param generationKey Exact generation identifier.
  /// @param debtSharesRepaid Debt shares retired by the vault.
  function _reduceDebtAttribution(
    LibDreamMarginStorage.State storage self,
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 debtSharesRepaid
  ) private {
    position.debtShares = _uint128(
      "POSITION_DEBT_SHARES", uint256(position.debtShares) - debtSharesRepaid
    );
    self.outcomeDebtShares[generationKey] -= debtSharesRepaid;
    self.marketDebtShares[config.marketGroup] -= debtSharesRepaid;
    self.totalDebtShares -= debtSharesRepaid;
  }

  /// @notice Requires mature size-aware value to place the position below maintenance health.
  /// @param position Position tested.
  /// @param config Exact generation risk policy.
  /// @param generationKey Exact generation identifier.
  /// @param positionId Position identifier used in errors.
  /// @return snapshot Eligibility values reused by the selected route.
  function _requireLiquidatable(
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 positionId
  ) private view returns (LiquidationSnapshot memory snapshot) {
    snapshot.generationKey = generationKey;
    snapshot.debtAssets = _vault().debtAssets(position.debtShares);
    uint256 seizureValue;
    (snapshot.liquidationValue, snapshot.oneOutcome, seizureValue) =
      _currentRecovery(position, config, generationKey);
    if (position.shares != 0) {
      snapshot.unitPrice =
        FixedPointMathLib.fullMulDiv(seizureValue, snapshot.oneOutcome, position.shares);
    }
    PositionHealth memory health =
      LibPositionRisk.positionHealth(snapshot.liquidationValue, snapshot.debtAssets);
    snapshot.maintenanceLtvBps = _maintenance(config, position.expiry);
    if (snapshot.maintenanceLtvBps != 0 && health.ltvBps <= snapshot.maintenanceLtvBps) {
      revert LibDreamMarginErrors.PositionNotLiquidatable(
        positionId, health.ltvBps, snapshot.maintenanceLtvBps
      );
    }
  }

  /// @notice Restores ACTIVE only at initial and maintenance health or reaches terminal zero state.
  /// @param position Position after actual repayment and seizure.
  /// @param config Exact generation risk policy.
  function _finalizePosition(Position storage position, GenerationConfig storage config) private {
    if (position.debtShares == 0) {
      position.status = position.shares == 0 ? PositionStatus.CLOSED : PositionStatus.ACTIVE;
      return;
    }
    if (position.shares == 0) {
      revert LibDreamMarginErrors.IncompleteClose(0, position.debtShares);
    }
    uint256 debtAssets = _vault().debtAssets(position.debtShares);
    if (debtAssets < config.risk.minDebt) {
      revert LibDreamMarginErrors.DebtCapExceeded("MIN_DEBT", debtAssets, config.risk.minDebt);
    }
    bytes32 generationKey = _generationKey(position);
    (uint256 value,,) = _currentRecovery(position, config, generationKey);
    PositionHealth memory health = LibPositionRisk.positionHealth(value, debtAssets);
    uint256 maintenanceLtvBps = _maintenance(config, position.expiry);
    uint256 maximumLtv =
      maintenanceLtvBps < config.risk.initialLtvBps ? maintenanceLtvBps : config.risk.initialLtvBps;
    if (maximumLtv == 0 || health.ltvBps > maximumLtv) {
      uint256 requiredValue = maximumLtv == 0
        ? type(uint256).max
        : FixedPointMathLib.fullMulDivUp(debtAssets, LibDreamMarginConstants.BPS, maximumLtv);
      revert LibDreamMarginErrors.InsufficientHealth(value, requiredValue);
    }
    position.status = PositionStatus.ACTIVE;
  }

  /// @notice Computes current position-sized executable recovery capped by mature TWAP.
  /// @param position Position valued.
  /// @param config Exact generation risk policy.
  /// @param generationKey Exact generation identifier.
  /// @return liquidationValue Conservative collateral value.
  /// @return oneOutcome Quantity representing one whole outcome.
  /// @return seizureValue Executable value capped by unhaircut TWAP for collateral-take pricing.
  function _currentRecovery(
    Position storage position,
    GenerationConfig storage config,
    bytes32 generationKey
  ) private view returns (uint256 liquidationValue, uint256 oneOutcome, uint256 seizureValue) {
    MarketKey memory key = _marketKey(position);
    ValidatedGeneration memory generation =
      _validateGeneration(_moduleAddress(), key, position.outcomeIndex, true);
    oneOutcome = generation.oneCollateral;
    // The oracle validates maturity, freshness, status, and generation identity.
    // forge-lint: disable-start(unused-return)
    (uint256 mark,,) = IDreamDexMarkOracle(_oracleAddress()).conservativeTwap(generationKey);
    // forge-lint: disable-end(unused-return)

    RecoveryBook memory book =
      _walkRecoveryBook(key, position.outcomeIndex, position.shares, config.risk.maxBookLevels);
    IDreamDexBinaryPool.BinaryPoolInfo memory info =
      IDreamDexBinaryPool(position.pool).getBinaryPoolParams();
    uint256 takerFeeBps = _feeBps(info.takerFeeBpsTimes1k, "TAKER_FEE");
    uint256 settlementFeeBps = _feeBps(info.settlementFeeBpsTimes1k, "SETTLEMENT_FEE");
    if (book.direct.complete && takerFeeBps != 0) {
      book.direct.value = FixedPointMathLib.fullMulDiv(
        book.direct.value, LibDreamMarginConstants.BPS - takerFeeBps, LibDreamMarginConstants.BPS
      );
    }
    if (book.opposite.complete && takerFeeBps != 0) {
      book.opposite
      .value += FixedPointMathLib.fullMulDivUp(
        book.opposite.value, takerFeeBps, LibDreamMarginConstants.BPS
      );
    }
    RecoveryValue memory recovery = LibPositionRisk.recoveryValue(
      position.shares,
      book.direct,
      book.opposite,
      info.setBacking,
      settlementFeeBps,
      mark,
      config.risk.collateralFactorBps,
      oneOutcome
    );
    liquidationValue = recovery.liquidationValue;
    uint256 unhaircutMarkValue =
      LibPositionRisk.collateralValueDown(position.shares, mark, oneOutcome);
    seizureValue =
      recovery.routeRecovery < unhaircutMarkValue ? recovery.routeRecovery : unhaircutMarkValue;
  }

  /// @notice Converts basis-points-times-one-thousand fees upward into basis points.
  /// @param feeTimes1k External fee value.
  /// @param field Field identifier used in errors.
  /// @return feeBps Conservative whole-basis-point fee.
  function _feeBps(uint256 feeTimes1k, bytes32 field) private pure returns (uint256 feeBps) {
    if (feeTimes1k > LibDreamMarginConstants.BPS_TIMES_1K) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        field, feeTimes1k, LibDreamMarginConstants.BPS_TIMES_1K
      );
    }
    feeBps = FixedPointMathLib.fullMulDivUp(feeTimes1k, 1, 1_000);
  }

  /// @notice Returns the expiry-compressed maintenance boundary at the current timestamp.
  /// @param config Exact generation risk policy.
  /// @param expiry Position trading expiry.
  /// @return maintenanceLtvBps Current liquidation boundary.
  function _maintenance(GenerationConfig storage config, uint256 expiry)
    private
    view
    returns (uint256 maintenanceLtvBps)
  {
    // Expiry compression is the liquidation boundary intentionally derived from block time.
    // forge-lint: disable-next-line(block-timestamp)
    uint256 timeToExpiry = expiry > block.timestamp ? expiry - block.timestamp : 0;
    maintenanceLtvBps = LibPositionRisk.maintenanceLtvBps(
      config.risk.maintenanceLtvBps, timeToExpiry, config.risk.compressionWindow
    );
  }

  /// @notice Returns one existing active position with nonzero debt.
  /// @param self Controller namespace.
  /// @param positionId Position identifier.
  /// @return position Active debt-bearing position storage reference.
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
    if (position.debtShares == 0) {
      revert LibDreamMarginErrors.PositionNotLiquidatable(positionId, 0, 0);
    }
  }

  /// @notice Reconstructs the exact market generation tuple stored in a position.
  /// @param position Position source.
  /// @return key Full market generation tuple.
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

  /// @notice Derives the exact generation identifier stored in a position.
  /// @param position Position source.
  /// @return generationKey Full generation hash.
  function _generationKey(Position storage position) private view returns (bytes32 generationKey) {
    generationKey = LibDreamMarginStorage.generationKey(_marketKey(position));
  }

  /// @notice Pulls exact liquidator collateral and rejects taxed transfers.
  /// @param asset Collateral token.
  /// @param payer Liquidator supplying assets.
  /// @param amount Exact amount required.
  function _pullAsset(address asset, address payer, uint256 amount) private {
    uint256 beforeBalance = IERC20Minimal(asset).balanceOf(address(this));
    // Permissionless liquidation intentionally pulls from the current liquidator only.
    // forge-lint: disable-next-line(arbitrary-send-erc20)
    asset.safeTransferFrom(payer, address(this), amount);
    uint256 afterBalance = IERC20Minimal(asset).balanceOf(address(this));
    if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(asset, beforeBalance + amount, afterBalance);
    }
  }

  /// @notice Sends exact collateral from controller custody.
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

  /// @notice Sends exact attributed outcome shares from controller custody.
  /// @param token ERC-6909 outcome token.
  /// @param outcomeId Exact outcome ID.
  /// @param receiver Liquidator receiving shares.
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
  /// @return vault_ Bound collateral vault.
  function _vault() private view returns (IDreamMarginVault vault_) {
    vault_ = IDreamMarginVault(IDreamMarginController(address(this)).vault());
  }

  /// @notice Returns the executing controller's immutable oracle.
  /// @return oracle_ Bound oracle address.
  function _oracleAddress() private view returns (address oracle_) {
    oracle_ = IDreamMarginController(address(this)).oracle();
  }

  /// @notice Narrows a stored position field after an explicit bound check.
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
