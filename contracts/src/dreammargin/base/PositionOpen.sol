// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin position opening
/// @author DreamMargin contributors
/// @notice Opens isolated leveraged positions and accepts debt-free collateral additions.
/// @dev Every open reconciles actual DreamDEX and vault deltas before recording shared state.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {DreamMarginReentrancyGuard} from "src/libs/dreammargin/DreamMarginReentrancyGuard.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  Position,
  PositionStatus,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibPositionRisk, PositionHealth} from "src/libs/dreammargin/LibPositionRisk.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Immutable opening facet executed only through selector-specific controller delegation.
contract PositionOpen is DreamDexAdapter, DreamMarginReentrancyGuard {
  using SafeTransferLib for address;

  /// @notice Intermediate values retained while one atomic opening is reconciled.
  /// @param generationKey Hash of the exact registered generation tuple.
  /// @param initialEquity Conservative value of owner-supplied outcome shares.
  /// @param targetDebt Requested nominal borrowing before execution reconciliation.
  /// @param debtShares Vault debt shares minted for the target borrowing.
  /// @param sharesBought Actual outcome-token balance increase from DreamDEX.
  /// @param collateralSpent Actual collateral-token balance decrease through DreamDEX.
  /// @param finalDebtShares Debt shares left after unused collateral is returned.
  /// @param finalDebtAssets Conservative asset value of final debt shares.
  struct OpenAccounting {
    bytes32 generationKey;
    uint256 initialEquity;
    uint256 targetDebt;
    uint256 debtShares;
    uint256 sharesBought;
    uint256 collateralSpent;
    uint256 finalDebtShares;
    uint256 finalDebtAssets;
  }

  /// @notice Opens one isolated leveraged position atomically through the controller.
  /// @param params Exact generation, collateral, leverage, price, fill, and deadline bounds.
  /// @return positionId Newly allocated position identifier.
  /// @return sharesBought Additional outcome shares received from actual execution deltas.
  /// @return debtAssets Collateral debt created in native units.
  function openPosition(IDreamMarginController.OpenParams calldata params)
    external
    nonReentrant
    returns (uint256 positionId, uint256 sharesBought, uint256 debtAssets)
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (self.mode != ProtocolMode.ACTIVE) {
      revert LibDreamMarginErrors.ActionBlocked(
        uint8(self.mode), IDreamMarginController.openPosition.selector
      );
    }
    if (params.initialShares == 0) revert LibDreamMarginErrors.ZeroAmount(params.initialShares);

    OpenAccounting memory accounting;
    accounting.generationKey = LibDreamMarginStorage.generationKey(params.key);
    GenerationConfig storage config = self.generations[accounting.generationKey];
    _requireOpenGeneration(config, accounting.generationKey, params);
    ValidatedGeneration memory generation =
      _validateGeneration(_moduleAddress(), params.key, params.outcomeIndex, true);
    _requireOpeningWindow(generation.expiry, config.risk.openingCutoff);

    // The oracle itself validates maturity, freshness, and a nonempty observation window.
    // forge-lint: disable-start(unused-return)
    (uint256 mark,,) =
      IDreamDexMarkOracle(_oracleAddress()).conservativeTwap(accounting.generationKey);
    // forge-lint: disable-end(unused-return)
    accounting.initialEquity =
      LibPositionRisk.collateralValueDown(params.initialShares, mark, generation.oneCollateral);
    if (accounting.initialEquity == 0) {
      revert LibDreamMarginErrors.InsufficientHealth(0, 1);
    }
    if (
      params.leverageBps <= LibDreamMarginConstants.BPS
        || params.leverageBps > config.risk.maxLeverageBps
    ) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "LEVERAGE_BPS", params.leverageBps, config.risk.maxLeverageBps
      );
    }
    if (
      params.limitPrice == 0 || params.limitPrice >= generation.oneCollateral
        || params.limitPrice % generation.orderBook.tickSize != 0
    ) revert LibDreamMarginErrors.InvalidTick(params.limitPrice, generation.orderBook.tickSize);
    uint256 sidePrice =
      params.outcomeIndex == 0 ? params.limitPrice : generation.oneCollateral - params.limitPrice;
    accounting.targetDebt = LibPositionRisk.targetDebtAtLimitDown(
      accounting.initialEquity, params.leverageBps, mark, sidePrice
    );
    if (accounting.targetDebt > params.maxCollateralIn) {
      revert LibDreamMarginErrors.ExcessiveCollateralIn(
        accounting.targetDebt, params.maxCollateralIn
      );
    }
    _requireDebtBounds(self, config, accounting.targetDebt);

    uint256 quantity =
      FixedPointMathLib.fullMulDiv(accounting.targetDebt, generation.oneCollateral, sidePrice);
    quantity -= quantity % generation.orderBook.lotSize;
    if (quantity == 0) {
      revert LibDreamMarginErrors.QuantizedToZero(
        accounting.targetDebt, generation.orderBook.lotSize
      );
    }

    _pullExactOutcome(
      params.key.outcomeToken, params.key.outcomeId, msg.sender, params.initialShares
    );
    IDreamMarginVault vault_ = IDreamMarginVault(_vaultAddress());
    accounting.debtShares = vault_.borrow(accounting.targetDebt, address(this));
    ExecutionResult memory execution = _buyOutcome(
      _moduleAddress(),
      ImmediateOrder({
        key: params.key,
        outcomeIndex: params.outcomeIndex,
        price: params.limitPrice,
        quantity: quantity,
        minimumOutput: params.minSharesOut,
        maximumInput: accounting.targetDebt,
        deadline: params.deadline,
        orderType: params.orderType,
        userData: _positionUserData(self.nextPositionId)
      })
    );
    accounting.sharesBought = execution.outcomeAmount;
    accounting.collateralSpent = execution.collateralAmount;
    accounting.finalDebtShares = _returnUnusedBorrow(
      vault_, accounting.debtShares, accounting.targetDebt - execution.collateralAmount
    );
    accounting.finalDebtAssets = vault_.debtAssets(accounting.finalDebtShares);

    uint256 resultingShares = params.initialShares + accounting.sharesBought;
    _requirePostTradeRisk(
      config,
      accounting.generationKey,
      resultingShares,
      accounting.finalDebtAssets,
      accounting.initialEquity,
      mark,
      generation.oneCollateral,
      params.leverageBps
    );
    _requireDebtBounds(self, config, accounting.finalDebtAssets);

    positionId = self.nextPositionId;
    self.nextPositionId = positionId + 1;
    self.positions[positionId] = Position({
      owner: msg.sender,
      marketId: params.key.marketId,
      pool: params.key.pool,
      outcomeToken: params.key.outcomeToken,
      outcomeId: params.key.outcomeId,
      shares: _uint128("POSITION_SHARES", resultingShares),
      debtShares: _uint128("POSITION_DEBT_SHARES", accounting.finalDebtShares),
      initialEquity: _uint128("INITIAL_EQUITY", accounting.initialEquity),
      marketNonce: params.key.marketNonce,
      openedAt: _timestamp40(),
      expiry: _uint40("EXPIRY", generation.expiry),
      outcomeIndex: params.outcomeIndex,
      status: PositionStatus.ACTIVE
    });
    self.attributedShares[params.key.outcomeToken][params.key.outcomeId] += resultingShares;
    self.outcomeDebtShares[accounting.generationKey] += accounting.finalDebtShares;
    self.marketDebtShares[config.marketGroup] += accounting.finalDebtShares;
    self.totalDebtShares += accounting.finalDebtShares;

    sharesBought = accounting.sharesBought;
    debtAssets = accounting.finalDebtAssets;
    emit IDreamMarginController.PositionOpened(
      positionId,
      msg.sender,
      accounting.generationKey,
      params.initialShares,
      sharesBought,
      debtAssets
    );
  }

  /// @notice Adds the exact recorded outcome ID without borrowing or trading.
  /// @param positionId Position receiving collateral.
  /// @param shares Outcome shares transferred from the caller.
  function addCollateral(uint256 positionId, uint256 shares) external nonReentrant {
    if (shares == 0) revert LibDreamMarginErrors.ZeroAmount(shares);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    Position storage position = self.positions[positionId];
    if (position.owner == address(0)) revert LibDreamMarginErrors.PositionNotFound(positionId);
    if (position.owner != msg.sender) {
      revert LibDreamMarginErrors.NotPositionOwner(msg.sender, position.owner, positionId);
    }
    if (position.status != PositionStatus.ACTIVE) {
      revert LibDreamMarginErrors.InvalidPositionStatus(
        positionId, uint8(position.status), uint8(PositionStatus.ACTIVE)
      );
    }

    _pullExactOutcome(position.outcomeToken, position.outcomeId, msg.sender, shares);
    uint256 resultingShares = uint256(position.shares) + shares;
    position.shares = _uint128("POSITION_SHARES", resultingShares);
    self.attributedShares[position.outcomeToken][position.outcomeId] += shares;
    // The namespaced guard remains locked across the exact-ID token interaction.
    // forge-lint: disable-next-line(reentrancy-events)
    emit IDreamMarginController.CollateralAdded(positionId, msg.sender, shares);
  }

  /// @notice Returns the immutable DreamDEX module through the executing controller facade.
  /// @return module_ Bound DreamDEX module.
  function _moduleAddress() internal view returns (address module_) {
    module_ = IDreamMarginController(address(this)).module();
  }

  /// @notice Returns the immutable collateral vault through the executing controller facade.
  /// @return vault_ Bound collateral vault.
  function _vaultAddress() internal view returns (address vault_) {
    vault_ = IDreamMarginController(address(this)).vault();
  }

  /// @notice Returns the immutable mark oracle through the executing controller facade.
  /// @return oracle_ Bound generation oracle.
  function _oracleAddress() internal view returns (address oracle_) {
    oracle_ = IDreamMarginController(address(this)).oracle();
  }

  /// @notice Requires an exact enabled controller record matching all opening parameters.
  /// @param config Stored generation configuration.
  /// @param generationKey Derived generation identifier.
  /// @param params User-supplied opening parameters.
  function _requireOpenGeneration(
    GenerationConfig storage config,
    bytes32 generationKey,
    IDreamMarginController.OpenParams calldata params
  ) private view {
    if (config.frozen) {
      revert LibDreamMarginErrors.GenerationFrozen(generationKey);
    }
    if (config.key.pool == address(0) || !config.enabled) {
      revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    }
    if (config.risk.outcomeIndex != params.outcomeIndex) {
      revert LibDreamMarginErrors.GenerationMismatch(
        generationKey, LibDreamMarginStorage.generationKey(params.key)
      );
    }
  }

  /// @notice Requires strictly more time than the configured no-borrow cutoff.
  /// @param expiry Market trading expiry in seconds.
  /// @param cutoff Required remaining seconds.
  function _requireOpeningWindow(uint256 expiry, uint256 cutoff) private view {
    // The expiry boundary deliberately stops new risk before venue trading ends.
    // forge-lint: disable-next-line(block-timestamp)
    if (expiry <= block.timestamp || expiry - block.timestamp <= cutoff) {
      revert LibDreamMarginErrors.OpeningCutoffReached(expiry, block.timestamp, cutoff);
    }
  }

  /// @notice Enforces position, outcome, market, global, and utilization debt ceilings.
  /// @param self Controller namespace containing aggregate debt shares.
  /// @param config Exact generation risk policy.
  /// @param addedDebt Conservative asset debt added by the position.
  function _requireDebtBounds(
    LibDreamMarginStorage.State storage self,
    GenerationConfig storage config,
    uint256 addedDebt
  ) private view {
    if (addedDebt < config.risk.minDebt) {
      revert LibDreamMarginErrors.DebtCapExceeded("MIN_DEBT", addedDebt, config.risk.minDebt);
    }
    _cap("POSITION_DEBT", addedDebt, config.risk.maxDebtPerPosition);
    IDreamMarginVault vault_ = IDreamMarginVault(_vaultAddress());
    _cap(
      "OUTCOME_DEBT",
      vault_.debtAssets(self.outcomeDebtShares[LibDreamMarginStorage.generationKey(config.key)])
        + addedDebt,
      config.risk.maxDebtPerOutcome
    );
    _cap(
      "MARKET_DEBT",
      vault_.debtAssets(self.marketDebtShares[config.marketGroup]) + addedDebt,
      config.risk.maxDebtPerMarket
    );
    uint256 resultingGlobal = vault_.debtAssets(self.totalDebtShares) + addedDebt;
    _cap("GLOBAL_DEBT", resultingGlobal, self.globalRisk.maxDebtGlobal);
    uint256 totalAssets = vault_.totalAssets();
    uint256 utilization = totalAssets == 0
      ? type(uint256).max
      : FixedPointMathLib.fullMulDivUp(resultingGlobal, LibDreamMarginConstants.BPS, totalAssets);
    if (utilization > self.globalRisk.maxVaultUtilizationBps) {
      revert LibDreamMarginErrors.UtilizationExceeded(
        utilization, self.globalRisk.maxVaultUtilizationBps
      );
    }
  }

  /// @notice Returns unused borrowed collateral and leaves no unattributed controller cash.
  /// @param vault_ Bound collateral vault.
  /// @param borrowedShares Debt shares minted by the opening borrow.
  /// @param unusedAssets Borrowed collateral not spent by DreamDEX.
  /// @return finalDebtShares Debt shares remaining after repayment.
  function _returnUnusedBorrow(
    IDreamMarginVault vault_,
    uint256 borrowedShares,
    uint256 unusedAssets
  ) private returns (uint256 finalDebtShares) {
    finalDebtShares = borrowedShares;
    if (unusedAssets == 0) return finalDebtShares;
    address asset = vault_.asset();
    asset.safeApproveWithRetry(address(vault_), unusedAssets);
    uint256 repayShares = LibPositionRisk.debtSharesDown(unusedAssets, vault_.debtIndexWad());
    uint256 repaidAssets = 0;
    if (repayShares != 0) {
      // The vault either retires the exact requested shares or reverts.
      // forge-lint: disable-next-line(unused-return)
      (repaidAssets,) = vault_.repay(repayShares, unusedAssets);
      finalDebtShares -= repayShares;
    }
    uint256 dust = unusedAssets - repaidAssets;
    if (dust != 0) {
      // The vault rejects reserve funding that would mint zero reserve shares.
      // forge-lint: disable-next-line(unused-return)
      vault_.fundReserve(dust);
    }
    asset.safeApproveWithRetry(address(vault_), 0);
  }

  /// @notice Enforces visible-depth and conservative post-execution health bounds.
  /// @param config Exact generation risk policy.
  /// @param generationKey Exact generation identifier.
  /// @param shares Total attributed shares after execution.
  /// @param debtAssets Final conservative debt in collateral units.
  /// @param initialEquity Owner equity recognized before borrowing.
  /// @param mark Mature conservative mark in collateral units.
  /// @param oneCollateral Whole-outcome scaling unit.
  /// @param requestedLeverage User's requested leverage ceiling.
  function _requirePostTradeRisk(
    GenerationConfig storage config,
    bytes32 generationKey,
    uint256 shares,
    uint256 debtAssets,
    uint256 initialEquity,
    uint256 mark,
    uint256 oneCollateral,
    uint256 requestedLeverage
  ) private view {
    // Conservative TWAP validation above already proved the ring is mature.
    // forge-lint: disable-start(unused-return)
    (OracleConfig memory oracleConfig,) =
      IDreamDexMarkOracle(_oracleAddress()).generationState(generationKey);
    // forge-lint: disable-end(unused-return)
    uint256 maxShares = FixedPointMathLib.fullMulDiv(
      oracleConfig.depthQuantity, config.risk.maxPositionDepthBps, LibDreamMarginConstants.BPS
    );
    if (shares > maxShares) {
      revert LibDreamMarginErrors.PositionDepthExceeded(shares, maxShares);
    }
    uint256 grossValue = LibPositionRisk.collateralValueDown(shares, mark, oneCollateral);
    PositionHealth memory health = LibPositionRisk.positionHealth(grossValue, debtAssets);
    if (health.ltvBps > config.risk.initialLtvBps) {
      uint256 requiredValue = FixedPointMathLib.fullMulDivUp(
        debtAssets, LibDreamMarginConstants.BPS, config.risk.initialLtvBps
      );
      revert LibDreamMarginErrors.InsufficientHealth(grossValue, requiredValue);
    }
    uint256 leverageCeiling = requestedLeverage < config.risk.maxLeverageBps
      ? requestedLeverage
      : config.risk.maxLeverageBps;
    // A borrow rounds debt shares up and their current asset value up again. Permit at most the
    // asset value of one debt-share quantum in owner-equity and nominal-leverage comparisons;
    // the independent initial-LTV check above remains strictly conservative.
    uint256 debtQuantum = FixedPointMathLib.fullMulDivUp(
      IDreamMarginVault(_vaultAddress()).debtIndexWad(), 1, LibDreamMarginConstants.WAD
    );
    uint256 minimumLeverageEquity =
      FixedPointMathLib.fullMulDivUp(grossValue, LibDreamMarginConstants.BPS, leverageCeiling);
    uint256 maximumLeverageDebt =
      grossValue > minimumLeverageEquity ? grossValue - minimumLeverageEquity : 0;
    bool exceededLeverage =
      debtAssets > maximumLeverageDebt && debtAssets - maximumLeverageDebt > debtQuantum;
    if (exceededLeverage) {
      revert LibDreamMarginErrors.InsufficientHealth(grossValue, debtAssets + initialEquity);
    }
  }

  /// @notice Pulls one exact outcome ID using only its per-ID user allowance.
  /// @param token ERC-6909 outcome-token contract.
  /// @param outcomeId Exact outcome ID transferred.
  /// @param owner Outcome owner granting allowance.
  /// @param shares Exact shares required.
  function _pullExactOutcome(address token, uint256 outcomeId, address owner, uint256 shares)
    private
  {
    IERC6909 outcome = IERC6909(token);
    uint256 available = outcome.allowance(owner, address(this), outcomeId);
    if (available < shares) {
      revert LibDreamMarginErrors.InsufficientOutcomeAllowance(token, outcomeId, available, shares);
    }
    uint256 beforeBalance = outcome.balanceOf(address(this), outcomeId);
    bool success = outcome.transferFrom(owner, address(this), outcomeId, shares);
    uint256 afterBalance = outcome.balanceOf(address(this), outcomeId);
    if (!success || afterBalance < beforeBalance || afterBalance - beforeBalance != shares) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(token, beforeBalance + shares, afterBalance);
    }
  }

  /// @notice Rejects debt above one named ceiling.
  /// @param scope Cap scope identifier.
  /// @param debt Resulting debt.
  /// @param maximum Configured ceiling.
  function _cap(bytes32 scope, uint256 debt, uint256 maximum) private pure {
    if (debt > maximum) revert LibDreamMarginErrors.DebtCapExceeded(scope, debt, maximum);
  }

  /// @notice Narrows a position field after an explicit representational check.
  /// @param field Field identifier.
  /// @param value Value narrowed.
  /// @return narrowed Checked 128-bit value.
  function _uint128(bytes32 field, uint256 value) private pure returns (uint128 narrowed) {
    if (value > type(uint128).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds(field, value, type(uint128).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    narrowed = uint128(value);
  }

  /// @notice Narrows a generation timestamp after an explicit bound check.
  /// @param field Field identifier.
  /// @param value Timestamp narrowed.
  /// @return narrowed Checked forty-bit value.
  function _uint40(bytes32 field, uint256 value) private pure returns (uint40 narrowed) {
    if (value > type(uint40).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds(field, value, type(uint40).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    narrowed = uint40(value);
  }

  /// @notice Returns the current timestamp after an explicit forty-bit bound check.
  /// @return timestamp Checked current timestamp.
  function _timestamp40() private view returns (uint40 timestamp) {
    // Timestamp manipulation cannot approach the forty-bit representational bound.
    // forge-lint: disable-next-line(block-timestamp)
    timestamp = _uint40("TIMESTAMP", block.timestamp);
  }

  /// @notice Encodes a position identifier in DreamDEX's bounded user-data field.
  /// @param positionId Position ID allocated if the open succeeds.
  /// @return userData Checked 64-bit attribution value.
  function _positionUserData(uint256 positionId) private pure returns (uint64 userData) {
    if (positionId > type(uint64).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("POSITION_ID", positionId, type(uint64).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    userData = uint64(positionId);
  }
}
