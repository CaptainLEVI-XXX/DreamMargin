// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// @title DreamMargin position risk mathematics
// @author DreamMargin contributors
// @notice Calculates conservative values, debt, health, recovery, and settlement.
// @dev Every rounding direction favors the vault; all economic choices are parameters.

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice One normalized executable book level.
/// @param price Collateral native units per whole outcome unit.
/// @param quantity Outcome quantity available at the price.
struct RiskBookLevel {
  uint256 price;
  uint256 quantity;
}

/// @notice Result of walking a bounded ordered book.
/// @param value Collateral proceeds rounded down for bids or cost rounded up for asks.
/// @param filledQuantity Outcome quantity covered by visible levels.
/// @param averagePrice Size-weighted unit price, rounded conservatively.
/// @param complete Whether visible levels covered the full requested quantity.
struct BookWalk {
  uint256 value;
  uint256 filledQuantity;
  uint256 averagePrice;
  bool complete;
}

/// @notice Conservative valuation assembled from direct, hedge, and TWAP-cap routes.
/// @param directRecovery Complete same-side bid recovery or zero when depth is insufficient.
/// @param hedgeRecovery Complete-set hedge recovery or zero when opposite depth is insufficient.
/// @param routeRecovery Larger executable route recovery.
/// @param markCap Haircut TWAP cap.
/// @param liquidationValue Smaller of route recovery and mark cap.
struct RecoveryValue {
  uint256 directRecovery;
  uint256 hedgeRecovery;
  uint256 routeRecovery;
  uint256 markCap;
  uint256 liquidationValue;
}

/// @notice Post-transition position health in collateral native units and basis points.
/// @param grossValue Conservative gross collateral value.
/// @param debtAssets Current debt rounded up.
/// @param equity Remaining nonnegative owner equity.
/// @param ltvBps Debt divided by gross value, rounded up.
/// @param leverageBps Gross value divided by equity, rounded up; maximum uint when equity is zero.
struct PositionHealth {
  uint256 grossValue;
  uint256 debtAssets;
  uint256 equity;
  uint256 ltvBps;
  uint256 leverageBps;
}

/// @notice Deterministic terminal recovery waterfall.
/// @param repaidAssets Recovery applied to the collectible receivable.
/// @param ownerAssets Genuine recovery surplus after debt repayment.
/// @param feesWaived Attributed protocol fees removed before reserve use.
/// @param reserveUsed Funded first-loss reserve consumed.
/// @param badDebt Remaining senior receivable written off exactly once.
struct SettlementWaterfall {
  uint256 repaidAssets;
  uint256 ownerAssets;
  uint256 feesWaived;
  uint256 reserveUsed;
  uint256 badDebt;
}

/// @title DreamMargin position risk calculations
/// @author DreamMargin contributors
/// @notice Implements parameterized, conservative integer economics for every lifecycle module.
/// @dev Full-precision Solady multiplication is used only with explicit nonzero denominators.
library LibPositionRisk {
  // -------------------------------------------------------------------------
  // Units and fixed-point conversion
  // -------------------------------------------------------------------------

  /// @notice Converts token units between decimal systems, rounded down when precision decreases.
  /// @param amount Amount in the source token's native units.
  /// @param fromDecimals Source precision, at most 18.
  /// @param toDecimals Destination precision, at most 18.
  /// @return normalized Amount in destination units, rounded down.
  function normalizeDown(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
    internal
    pure
    returns (uint256 normalized)
  {
    _checkDecimals(fromDecimals);
    _checkDecimals(toDecimals);
    if (fromDecimals == toDecimals) return amount;
    if (fromDecimals < toDecimals) return amount * (10 ** (toDecimals - fromDecimals));
    normalized = amount / (10 ** (fromDecimals - toDecimals));
  }

  /// @notice Converts token units between decimal systems, rounded up when precision decreases.
  /// @param amount Amount in the source token's native units.
  /// @param fromDecimals Source precision, at most 18.
  /// @param toDecimals Destination precision, at most 18.
  /// @return normalized Amount in destination units, rounded up.
  function normalizeUp(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
    internal
    pure
    returns (uint256 normalized)
  {
    _checkDecimals(fromDecimals);
    _checkDecimals(toDecimals);
    if (fromDecimals == toDecimals) return amount;
    if (fromDecimals < toDecimals) return amount * (10 ** (toDecimals - fromDecimals));
    uint256 divisor = 10 ** (fromDecimals - toDecimals);
    normalized = amount / divisor;
    if (amount % divisor != 0) ++normalized;
  }

  /// @notice Values outcome shares at a unit price, rounded down in collateral native units.
  /// @param shares Outcome quantity.
  /// @param unitPrice Collateral units per `oneOutcome` quantity.
  /// @param oneOutcome Quantity representing one whole outcome token.
  /// @return assets Conservative collateral value rounded down.
  function collateralValueDown(uint256 shares, uint256 unitPrice, uint256 oneOutcome)
    internal
    pure
    returns (uint256 assets)
  {
    _nonzero(oneOutcome, "ONE_OUTCOME");
    assets = FixedPointMathLib.fullMulDiv(shares, unitPrice, oneOutcome);
  }

  /// @notice Computes nominal target debt from initial equity and requested gross leverage.
  /// @param equity Initial equity in collateral native units.
  /// @param leverageBps Gross leverage in basis points, where 10,000 is 1x.
  /// @return debt Target principal rounded down.
  function targetDebtDown(uint256 equity, uint256 leverageBps)
    internal
    pure
    returns (uint256 debt)
  {
    if (leverageBps < LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "LEVERAGE_BPS", leverageBps, LibDreamMarginConstants.BPS
      );
    }
    debt = FixedPointMathLib.fullMulDiv(
      equity, leverageBps - LibDreamMarginConstants.BPS, LibDreamMarginConstants.BPS
    );
  }

  // -------------------------------------------------------------------------
  // Debt, interest, and vault shares
  // -------------------------------------------------------------------------

  /// @notice Converts debt shares to assets at a WAD index, rounded up.
  /// @param debtShares Debt shares.
  /// @param debtIndexWad Assets per debt share in WAD.
  /// @return assets Collectible debt in collateral native units.
  function debtAssetsUp(uint256 debtShares, uint256 debtIndexWad)
    internal
    pure
    returns (uint256 assets)
  {
    _nonzero(debtIndexWad, "DEBT_INDEX");
    assets = FixedPointMathLib.fullMulDivUp(debtShares, debtIndexWad, LibDreamMarginConstants.WAD);
  }

  /// @notice Converts borrowed assets to debt shares at a WAD index, rounded up.
  /// @param assets Borrowed collateral in native units.
  /// @param debtIndexWad Assets per debt share in WAD.
  /// @return debtShares Debt shares created.
  function debtSharesUp(uint256 assets, uint256 debtIndexWad)
    internal
    pure
    returns (uint256 debtShares)
  {
    _nonzero(debtIndexWad, "DEBT_INDEX");
    debtShares = FixedPointMathLib.fullMulDivUp(assets, LibDreamMarginConstants.WAD, debtIndexWad);
  }

  /// @notice Accrues a simple annualized WAD financing rate, rounded up.
  /// @param debtIndexWad Current nonzero debt index.
  /// @param annualRateWad Annual simple financing rate in WAD.
  /// @param elapsed Seconds since the previous accrual.
  /// @return nextIndexWad Updated debt index rounded up.
  function accrueDebtIndexUp(uint256 debtIndexWad, uint256 annualRateWad, uint256 elapsed)
    internal
    pure
    returns (uint256 nextIndexWad)
  {
    _nonzero(debtIndexWad, "DEBT_INDEX");
    if (elapsed == 0 || annualRateWad == 0) return debtIndexWad;
    uint256 timeRateWad = FixedPointMathLib.fullMulDivUp(
      annualRateWad, elapsed, LibDreamMarginConstants.SECONDS_PER_YEAR
    );
    uint256 interest =
      FixedPointMathLib.fullMulDivUp(debtIndexWad, timeRateWad, LibDreamMarginConstants.WAD);
    nextIndexWad = debtIndexWad + interest;
  }

  /// @notice Converts deposited assets to vault shares with virtual-offset inflation defense.
  /// @param assets Deposited collateral.
  /// @param totalSupply Existing redeemable share supply.
  /// @param totalAssets Existing reported assets.
  /// @param virtualShares Nonzero virtual share offset.
  /// @param virtualAssets Nonzero virtual asset offset.
  /// @return shares Minted shares rounded down.
  function vaultSharesDown(
    uint256 assets,
    uint256 totalSupply,
    uint256 totalAssets,
    uint256 virtualShares,
    uint256 virtualAssets
  ) internal pure returns (uint256 shares) {
    _nonzero(virtualShares, "VIRTUAL_SHARES");
    _nonzero(virtualAssets, "VIRTUAL_ASSETS");
    shares = FixedPointMathLib.fullMulDiv(
      assets, totalSupply + virtualShares, totalAssets + virtualAssets
    );
  }

  /// @notice Converts requested vault shares to required assets, rounded up.
  /// @param shares Requested vault shares.
  /// @param totalSupply Existing redeemable share supply.
  /// @param totalAssets Existing reported assets.
  /// @param virtualShares Nonzero virtual share offset.
  /// @param virtualAssets Nonzero virtual asset offset.
  /// @return assets Required collateral rounded up.
  function vaultAssetsUp(
    uint256 shares,
    uint256 totalSupply,
    uint256 totalAssets,
    uint256 virtualShares,
    uint256 virtualAssets
  ) internal pure returns (uint256 assets) {
    _nonzero(virtualShares, "VIRTUAL_SHARES");
    _nonzero(virtualAssets, "VIRTUAL_ASSETS");
    assets = FixedPointMathLib.fullMulDivUp(
      shares, totalAssets + virtualAssets, totalSupply + virtualShares
    );
  }

  /// @notice Converts redeemable vault shares to assets, rounded down.
  /// @param shares Redeemed vault shares.
  /// @param totalSupply Existing redeemable share supply.
  /// @param totalAssets Existing reported assets.
  /// @param virtualShares Nonzero virtual share offset.
  /// @param virtualAssets Nonzero virtual asset offset.
  /// @return assets Payable collateral rounded down.
  function vaultAssetsDown(
    uint256 shares,
    uint256 totalSupply,
    uint256 totalAssets,
    uint256 virtualShares,
    uint256 virtualAssets
  ) internal pure returns (uint256 assets) {
    _nonzero(virtualShares, "VIRTUAL_SHARES");
    _nonzero(virtualAssets, "VIRTUAL_ASSETS");
    assets = FixedPointMathLib.fullMulDiv(
      shares, totalAssets + virtualAssets, totalSupply + virtualShares
    );
  }

  /// @notice Converts a requested asset withdrawal to shares burned, rounded up.
  /// @param assets Requested collateral.
  /// @param totalSupply Existing redeemable share supply.
  /// @param totalAssets Existing reported assets.
  /// @param virtualShares Nonzero virtual share offset.
  /// @param virtualAssets Nonzero virtual asset offset.
  /// @return shares Shares burned rounded up.
  function vaultSharesUp(
    uint256 assets,
    uint256 totalSupply,
    uint256 totalAssets,
    uint256 virtualShares,
    uint256 virtualAssets
  ) internal pure returns (uint256 shares) {
    _nonzero(virtualShares, "VIRTUAL_SHARES");
    _nonzero(virtualAssets, "VIRTUAL_ASSETS");
    shares = FixedPointMathLib.fullMulDivUp(
      assets, totalSupply + virtualShares, totalAssets + virtualAssets
    );
  }

  // -------------------------------------------------------------------------
  // Venue quantization and executable depth
  // -------------------------------------------------------------------------

  /// @notice Quantizes a value down to a venue tick or lot.
  /// @param value Requested raw value.
  /// @param quantum Nonzero tick or lot increment.
  /// @return quantized Largest valid value not exceeding the request.
  function quantizeDown(uint256 value, uint256 quantum) internal pure returns (uint256 quantized) {
    _nonzero(quantum, "QUANTUM");
    quantized = value - value % quantum;
    if (value != 0 && quantized == 0) revert LibDreamMarginErrors.QuantizedToZero(value, quantum);
  }

  /// @notice Quantizes a value up to a venue tick or lot.
  /// @param value Requested raw value.
  /// @param quantum Nonzero tick or lot increment.
  /// @return quantized Smallest valid value not below the request.
  function quantizeUp(uint256 value, uint256 quantum) internal pure returns (uint256 quantized) {
    _nonzero(quantum, "QUANTUM");
    if (value == 0) return 0;
    quantized = value - 1;
    quantized = quantized - quantized % quantum + quantum;
  }

  /// @notice Walks normalized same-side bids for a requested outcome quantity.
  /// @param levels Descending executable bid levels.
  /// @param quantity Requested outcome quantity.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @return walk Proceeds rounded down; incomplete depth is explicitly marked.
  function walkBidsDown(RiskBookLevel[] memory levels, uint256 quantity, uint256 oneOutcome)
    internal
    pure
    returns (BookWalk memory walk)
  {
    _nonzero(oneOutcome, "ONE_OUTCOME");
    uint256 remaining = quantity;
    uint256 length = levels.length;
    for (uint256 i = 0; i < length && remaining != 0; ++i) {
      uint256 fill = levels[i].quantity < remaining ? levels[i].quantity : remaining;
      walk.value += FixedPointMathLib.fullMulDiv(fill, levels[i].price, oneOutcome);
      walk.filledQuantity += fill;
      remaining -= fill;
    }
    walk.complete = remaining == 0;
    if (walk.filledQuantity != 0) {
      walk.averagePrice = FixedPointMathLib.fullMulDiv(walk.value, oneOutcome, walk.filledQuantity);
    }
  }

  /// @notice Walks normalized opposite-side asks for a requested outcome quantity.
  /// @param levels Ascending executable ask levels.
  /// @param quantity Requested outcome quantity.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @return walk Cost rounded up; incomplete depth is explicitly marked.
  function walkAsksUp(RiskBookLevel[] memory levels, uint256 quantity, uint256 oneOutcome)
    internal
    pure
    returns (BookWalk memory walk)
  {
    _nonzero(oneOutcome, "ONE_OUTCOME");
    uint256 remaining = quantity;
    uint256 length = levels.length;
    for (uint256 i = 0; i < length && remaining != 0; ++i) {
      uint256 fill = levels[i].quantity < remaining ? levels[i].quantity : remaining;
      walk.value += FixedPointMathLib.fullMulDivUp(fill, levels[i].price, oneOutcome);
      walk.filledQuantity += fill;
      remaining -= fill;
    }
    walk.complete = remaining == 0;
    if (walk.filledQuantity != 0) {
      walk.averagePrice =
        FixedPointMathLib.fullMulDivUp(walk.value, oneOutcome, walk.filledQuantity);
    }
  }

  // -------------------------------------------------------------------------
  // Recovery, health, and expiry
  // -------------------------------------------------------------------------

  /// @notice Combines executable routes with a haircut TWAP cap.
  /// @param quantity Held outcome quantity.
  /// @param direct Same-side bid walk.
  /// @param oppositeAsk Opposite-side ask walk for a complete-set hedge.
  /// @param completeSetBacking Gross collateral backing `oneOutcome` complete set.
  /// @param mergeFeeBps Complete-set merge and settlement cost in basis points.
  /// @param conservativeTwap Mature time-weighted unit mark.
  /// @param collateralFactorBps TWAP haircut in basis points.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @return recovery Conservative route and cap breakdown.
  function recoveryValue(
    uint256 quantity,
    BookWalk memory direct,
    BookWalk memory oppositeAsk,
    uint256 completeSetBacking,
    uint256 mergeFeeBps,
    uint256 conservativeTwap,
    uint256 collateralFactorBps,
    uint256 oneOutcome
  ) internal pure returns (RecoveryValue memory recovery) {
    if (mergeFeeBps > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps("MERGE_FEE", mergeFeeBps);
    }
    if (collateralFactorBps > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps("COLLATERAL_FACTOR", collateralFactorBps);
    }
    recovery.directRecovery = direct.complete ? direct.value : 0;
    if (oppositeAsk.complete) {
      uint256 gross = collateralValueDown(quantity, completeSetBacking, oneOutcome);
      uint256 fee = FixedPointMathLib.fullMulDivUp(gross, mergeFeeBps, LibDreamMarginConstants.BPS);
      uint256 cost = oppositeAsk.value + fee;
      recovery.hedgeRecovery = gross > cost ? gross - cost : 0;
    }
    recovery.routeRecovery = recovery.directRecovery > recovery.hedgeRecovery
      ? recovery.directRecovery
      : recovery.hedgeRecovery;
    uint256 unhaircutMark = collateralValueDown(quantity, conservativeTwap, oneOutcome);
    recovery.markCap =
      FixedPointMathLib.fullMulDiv(unhaircutMark, collateralFactorBps, LibDreamMarginConstants.BPS);
    recovery.liquidationValue =
      recovery.routeRecovery < recovery.markCap ? recovery.routeRecovery : recovery.markCap;
  }

  /// @notice Computes a TWAP from two cumulative mark-second observations.
  /// @param olderCumulative Older cumulative mark-seconds.
  /// @param newerCumulative Newer cumulative mark-seconds.
  /// @param elapsed Observation separation in seconds.
  /// @return twap Unit mark rounded down.
  function twapDown(uint256 olderCumulative, uint256 newerCumulative, uint256 elapsed)
    internal
    pure
    returns (uint256 twap)
  {
    _nonzero(elapsed, "TWAP_ELAPSED");
    if (newerCumulative < olderCumulative) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "CUMULATIVE_MARK", newerCumulative, olderCumulative
      );
    }
    twap = (newerCumulative - olderCumulative) / elapsed;
  }

  /// @notice Computes nonnegative equity, LTV, and effective leverage conservatively.
  /// @param grossValue Conservative collateral value.
  /// @param debtAssets Current debt already rounded up.
  /// @return health Complete position-health breakdown.
  function positionHealth(uint256 grossValue, uint256 debtAssets)
    internal
    pure
    returns (PositionHealth memory health)
  {
    health.grossValue = grossValue;
    health.debtAssets = debtAssets;
    health.equity = grossValue > debtAssets ? grossValue - debtAssets : 0;
    if (debtAssets == 0) {
      health.ltvBps = 0;
    } else if (grossValue == 0) {
      health.ltvBps = type(uint256).max;
    } else {
      health.ltvBps =
        FixedPointMathLib.fullMulDivUp(debtAssets, LibDreamMarginConstants.BPS, grossValue);
    }
    if (grossValue == 0) {
      health.leverageBps = 0;
    } else if (health.equity == 0) {
      health.leverageBps = type(uint256).max;
    } else {
      health.leverageBps =
        FixedPointMathLib.fullMulDivUp(grossValue, LibDreamMarginConstants.BPS, health.equity);
    }
  }

  /// @notice Compresses maintenance LTV monotonically toward zero near expiry.
  /// @param baseMaintenanceLtvBps Normal maintenance LTV in basis points.
  /// @param timeToExpiry Remaining seconds, zero at or after expiry.
  /// @param compressionWindow Seconds over which the threshold tightens.
  /// @return maintenanceLtvBps_ Current threshold rounded down.
  function maintenanceLtvBps(
    uint256 baseMaintenanceLtvBps,
    uint256 timeToExpiry,
    uint256 compressionWindow
  ) internal pure returns (uint256 maintenanceLtvBps_) {
    if (baseMaintenanceLtvBps > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps("MAINTENANCE_LTV", baseMaintenanceLtvBps);
    }
    _nonzero(compressionWindow, "COMPRESSION_WINDOW");
    if (timeToExpiry >= compressionWindow) return baseMaintenanceLtvBps;
    maintenanceLtvBps_ =
      FixedPointMathLib.fullMulDiv(baseMaintenanceLtvBps, timeToExpiry, compressionWindow);
  }

  /// @notice Returns whether debt remains inside an inclusive configured ceiling.
  /// @param currentDebt Existing debt in a cap scope.
  /// @param addedDebt Proposed additional debt.
  /// @param maximumDebt Inclusive configured ceiling.
  /// @return within True only when addition cannot overflow and resulting debt is within the cap.
  function withinDebtCap(uint256 currentDebt, uint256 addedDebt, uint256 maximumDebt)
    internal
    pure
    returns (bool within)
  {
    if (addedDebt > maximumDebt) return false;
    within = currentDebt <= maximumDebt - addedDebt;
  }

  /// @notice Calculates outcome shares seized for debt plus bonus, rounded up and balance-capped.
  /// @param debtAssets Debt repaid in collateral native units.
  /// @param bonusBps Liquidation incentive in basis points.
  /// @param unitPrice Conservative collateral price per whole outcome.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @param availableShares Actual attributed shares available.
  /// @return seized Outcome shares seized.
  function liquidationSharesUp(
    uint256 debtAssets,
    uint256 bonusBps,
    uint256 unitPrice,
    uint256 oneOutcome,
    uint256 availableShares
  ) internal pure returns (uint256 seized) {
    if (bonusBps > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps("LIQUIDATION_BONUS", bonusBps);
    }
    _nonzero(unitPrice, "UNIT_PRICE");
    _nonzero(oneOutcome, "ONE_OUTCOME");
    uint256 repaymentWithBonus = FixedPointMathLib.fullMulDivUp(
      debtAssets, LibDreamMarginConstants.BPS + bonusBps, LibDreamMarginConstants.BPS
    );
    seized = FixedPointMathLib.fullMulDivUp(repaymentWithBonus, oneOutcome, unitPrice);
    if (seized > availableShares) seized = availableShares;
  }

  // -------------------------------------------------------------------------
  // Terminal settlement
  // -------------------------------------------------------------------------

  /// @notice Values a terminal payout fraction after settlement fees, rounded down.
  /// @param shares Redeemed outcome quantity.
  /// @param backing Collateral backing one whole outcome.
  /// @param payoutNumerator Frozen payout numerator for the outcome.
  /// @param payoutDenominator Sum or configured denominator of payout numerators.
  /// @param settlementFeeBps Settlement fee in basis points.
  /// @param oneOutcome Quantity representing one whole outcome.
  /// @return assets Net redeemable collateral rounded down.
  function terminalPayoutDown(
    uint256 shares,
    uint256 backing,
    uint256 payoutNumerator,
    uint256 payoutDenominator,
    uint256 settlementFeeBps,
    uint256 oneOutcome
  ) internal pure returns (uint256 assets) {
    _nonzero(payoutDenominator, "PAYOUT_DENOMINATOR");
    if (settlementFeeBps > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps("SETTLEMENT_FEE", settlementFeeBps);
    }
    uint256 grossBacking = collateralValueDown(shares, backing, oneOutcome);
    uint256 grossPayout =
      FixedPointMathLib.fullMulDiv(grossBacking, payoutNumerator, payoutDenominator);
    assets = FixedPointMathLib.fullMulDiv(
      grossPayout, LibDreamMarginConstants.BPS - settlementFeeBps, LibDreamMarginConstants.BPS
    );
  }

  /// @notice Applies recovery to debt, attributed fees, reserve, bad debt, and owner surplus.
  /// @param recoveryAssets Actual collateral received.
  /// @param debtAssets Total collectible receivable before write-off.
  /// @param attributedFees Protocol fees included within that receivable.
  /// @param fundedReserve Available non-redeemable first-loss reserve.
  /// @return waterfall Deterministic loss and surplus allocation.
  function settlementWaterfall(
    uint256 recoveryAssets,
    uint256 debtAssets,
    uint256 attributedFees,
    uint256 fundedReserve
  ) internal pure returns (SettlementWaterfall memory waterfall) {
    if (attributedFees > debtAssets) {
      revert LibDreamMarginErrors.ValueOutOfBounds("ATTRIBUTED_FEES", attributedFees, debtAssets);
    }
    waterfall.repaidAssets = recoveryAssets < debtAssets ? recoveryAssets : debtAssets;
    waterfall.ownerAssets = recoveryAssets > debtAssets ? recoveryAssets - debtAssets : 0;
    uint256 shortfall = debtAssets - waterfall.repaidAssets;
    waterfall.feesWaived = shortfall < attributedFees ? shortfall : attributedFees;
    shortfall -= waterfall.feesWaived;
    waterfall.reserveUsed = shortfall < fundedReserve ? shortfall : fundedReserve;
    waterfall.badDebt = shortfall - waterfall.reserveUsed;
  }

  /// @notice Validates one supported collateral decimal precision.
  /// @param decimals Token precision checked.
  function _checkDecimals(uint8 decimals) private pure {
    if (decimals > LibDreamMarginConstants.MAX_COLLATERAL_DECIMALS) {
      revert LibDreamMarginErrors.UnsupportedDecimals(
        decimals, LibDreamMarginConstants.MAX_COLLATERAL_DECIMALS
      );
    }
  }

  /// @notice Requires a nonzero denominator before full-precision division.
  /// @param value Denominator checked.
  /// @param field Identifier of the denominator.
  function _nonzero(uint256 value, bytes32 field) private pure {
    if (value == 0) revert LibDreamMarginErrors.ZeroDenominator(field);
  }
}
