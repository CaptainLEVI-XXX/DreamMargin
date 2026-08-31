// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Position-risk mathematics test harness
/// @author DreamMargin contributors
/// @notice Exposes pure internal DreamMargin risk helpers to unit and differential tests.
/// @dev The harness has no state and does not alter library inputs or outputs.

import {
  BookWalk,
  LibPositionRisk,
  PositionHealth,
  RecoveryValue,
  RiskBookLevel,
  SettlementWaterfall
} from "src/libs/dreammargin/LibPositionRisk.sol";

/// @notice Stateless external wrapper for the pure risk library.
contract PositionRiskHarness {
  /// @notice Exposes downward decimal normalization.
  /// @param amount Source native units.
  /// @param fromDecimals Source precision.
  /// @param toDecimals Destination precision.
  /// @return normalized Destination units rounded down.
  function normalizeDown(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
    external
    pure
    returns (uint256 normalized)
  {
    normalized = LibPositionRisk.normalizeDown(amount, fromDecimals, toDecimals);
  }

  /// @notice Exposes upward decimal normalization.
  /// @param amount Source native units.
  /// @param fromDecimals Source precision.
  /// @param toDecimals Destination precision.
  /// @return normalized Destination units rounded up.
  function normalizeUp(uint256 amount, uint8 fromDecimals, uint8 toDecimals)
    external
    pure
    returns (uint256 normalized)
  {
    normalized = LibPositionRisk.normalizeUp(amount, fromDecimals, toDecimals);
  }

  /// @notice Exposes collateral valuation.
  /// @param shares Outcome quantity.
  /// @param price Unit price.
  /// @param one Whole-outcome unit.
  /// @return assets Collateral rounded down.
  function collateralValueDown(uint256 shares, uint256 price, uint256 one)
    external
    pure
    returns (uint256 assets)
  {
    assets = LibPositionRisk.collateralValueDown(shares, price, one);
  }

  /// @notice Exposes target debt calculation.
  /// @param equity Initial equity.
  /// @param leverageBps Gross leverage in basis points.
  /// @return debt Target debt rounded down.
  function targetDebtDown(uint256 equity, uint256 leverageBps)
    external
    pure
    returns (uint256 debt)
  {
    debt = LibPositionRisk.targetDebtDown(equity, leverageBps);
  }

  /// @notice Exposes debt assets rounded up.
  /// @param shares Debt shares.
  /// @param indexWad Debt index in WAD.
  /// @return assets Debt assets.
  function debtAssetsUp(uint256 shares, uint256 indexWad) external pure returns (uint256 assets) {
    assets = LibPositionRisk.debtAssetsUp(shares, indexWad);
  }

  /// @notice Exposes debt shares rounded up.
  /// @param assets Borrowed assets.
  /// @param indexWad Debt index in WAD.
  /// @return shares Debt shares.
  function debtSharesUp(uint256 assets, uint256 indexWad) external pure returns (uint256 shares) {
    shares = LibPositionRisk.debtSharesUp(assets, indexWad);
  }

  /// @notice Exposes linear debt-index accrual.
  /// @param indexWad Current index.
  /// @param annualRateWad Annual simple rate.
  /// @param elapsed Elapsed seconds.
  /// @return next Updated index rounded up.
  function accrueDebtIndexUp(uint256 indexWad, uint256 annualRateWad, uint256 elapsed)
    external
    pure
    returns (uint256 next)
  {
    next = LibPositionRisk.accrueDebtIndexUp(indexWad, annualRateWad, elapsed);
  }

  /// @notice Exposes all virtual-offset vault conversion directions.
  /// @param amount Assets for share conversions or shares for asset conversions.
  /// @param supply Existing share supply.
  /// @param assets Existing reported assets.
  /// @param virtualShares Virtual shares.
  /// @param virtualAssets Virtual assets.
  /// @return sharesDown Deposit shares rounded down.
  /// @return sharesUp Withdrawal shares rounded up.
  /// @return assetsDown Redemption assets rounded down.
  /// @return assetsUp Mint assets rounded up.
  function vaultConversions(
    uint256 amount,
    uint256 supply,
    uint256 assets,
    uint256 virtualShares,
    uint256 virtualAssets
  )
    external
    pure
    returns (uint256 sharesDown, uint256 sharesUp, uint256 assetsDown, uint256 assetsUp)
  {
    sharesDown =
      LibPositionRisk.vaultSharesDown(amount, supply, assets, virtualShares, virtualAssets);
    sharesUp = LibPositionRisk.vaultSharesUp(amount, supply, assets, virtualShares, virtualAssets);
    assetsDown =
      LibPositionRisk.vaultAssetsDown(amount, supply, assets, virtualShares, virtualAssets);
    assetsUp = LibPositionRisk.vaultAssetsUp(amount, supply, assets, virtualShares, virtualAssets);
  }

  /// @notice Exposes downward and upward venue quantization.
  /// @param value Requested value.
  /// @param quantum Tick or lot increment.
  /// @return down Quantized down.
  /// @return up Quantized up.
  function quantize(uint256 value, uint256 quantum)
    external
    pure
    returns (uint256 down, uint256 up)
  {
    down = LibPositionRisk.quantizeDown(value, quantum);
    up = LibPositionRisk.quantizeUp(value, quantum);
  }

  /// @notice Exposes conservative bid walking.
  /// @param levels Ordered normalized bids.
  /// @param quantity Requested quantity.
  /// @param one Whole-outcome unit.
  /// @return walk Balance-safe bid result.
  function walkBids(RiskBookLevel[] calldata levels, uint256 quantity, uint256 one)
    external
    pure
    returns (BookWalk memory walk)
  {
    walk = LibPositionRisk.walkBidsDown(levels, quantity, one);
  }

  /// @notice Exposes conservative ask walking.
  /// @param levels Ordered normalized asks.
  /// @param quantity Requested quantity.
  /// @param one Whole-outcome unit.
  /// @return walk Balance-safe ask result.
  function walkAsks(RiskBookLevel[] calldata levels, uint256 quantity, uint256 one)
    external
    pure
    returns (BookWalk memory walk)
  {
    walk = LibPositionRisk.walkAsksUp(levels, quantity, one);
  }

  /// @notice Exposes conservative route and TWAP-cap valuation.
  /// @param quantity Held outcome quantity.
  /// @param direct Same-side bid walk.
  /// @param opposite Opposite-side ask walk.
  /// @param backing Complete-set backing.
  /// @param mergeFeeBps Merge fee.
  /// @param twapValue Conservative TWAP.
  /// @param collateralFactorBps TWAP haircut.
  /// @param one Whole-outcome unit.
  /// @return result Complete recovery breakdown.
  function recovery(
    uint256 quantity,
    BookWalk calldata direct,
    BookWalk calldata opposite,
    uint256 backing,
    uint256 mergeFeeBps,
    uint256 twapValue,
    uint256 collateralFactorBps,
    uint256 one
  ) external pure returns (RecoveryValue memory result) {
    result = LibPositionRisk.recoveryValue(
      quantity, direct, opposite, backing, mergeFeeBps, twapValue, collateralFactorBps, one
    );
  }

  /// @notice Exposes position-health calculation.
  /// @param gross Conservative gross value.
  /// @param debt Current debt.
  /// @return result Health breakdown.
  function health(uint256 gross, uint256 debt)
    external
    pure
    returns (PositionHealth memory result)
  {
    result = LibPositionRisk.positionHealth(gross, debt);
  }

  /// @notice Exposes expiry compression.
  /// @param base Base maintenance LTV.
  /// @param remaining Seconds to expiry.
  /// @param window Compression window.
  /// @return current Current maintenance LTV.
  function maintenance(uint256 base, uint256 remaining, uint256 window)
    external
    pure
    returns (uint256 current)
  {
    current = LibPositionRisk.maintenanceLtvBps(base, remaining, window);
  }

  /// @notice Exposes cumulative-mark TWAP calculation.
  /// @param older Older cumulative mark-seconds.
  /// @param newer Newer cumulative mark-seconds.
  /// @param elapsed Observation separation in seconds.
  /// @return result Unit mark rounded down.
  function cumulativeTwap(uint256 older, uint256 newer, uint256 elapsed)
    external
    pure
    returns (uint256 result)
  {
    result = LibPositionRisk.twapDown(older, newer, elapsed);
  }

  /// @notice Exposes overflow-safe inclusive debt-cap admission.
  /// @param current Existing scoped debt.
  /// @param added Proposed added debt.
  /// @param maximum Inclusive debt cap.
  /// @return within Whether the resulting debt is inside the cap.
  function withinDebtCap(uint256 current, uint256 added, uint256 maximum)
    external
    pure
    returns (bool within)
  {
    within = LibPositionRisk.withinDebtCap(current, added, maximum);
  }

  /// @notice Exposes liquidation share calculation.
  /// @param debt Debt repaid.
  /// @param bonusBps Liquidation bonus.
  /// @param price Conservative unit price.
  /// @param one Whole-outcome unit.
  /// @param available Actual shares available.
  /// @return seized Shares seized rounded up and capped.
  function liquidationShares(
    uint256 debt,
    uint256 bonusBps,
    uint256 price,
    uint256 one,
    uint256 available
  ) external pure returns (uint256 seized) {
    seized = LibPositionRisk.liquidationSharesUp(debt, bonusBps, price, one, available);
  }

  /// @notice Exposes terminal payout calculation.
  /// @param shares Redeemed shares.
  /// @param backing Complete-set backing.
  /// @param numerator Outcome payout numerator.
  /// @param denominator Payout denominator.
  /// @param feeBps Settlement fee.
  /// @param one Whole-outcome unit.
  /// @return assets Net payout rounded down.
  function terminalPayout(
    uint256 shares,
    uint256 backing,
    uint256 numerator,
    uint256 denominator,
    uint256 feeBps,
    uint256 one
  ) external pure returns (uint256 assets) {
    assets = LibPositionRisk.terminalPayoutDown(
      shares, backing, numerator, denominator, feeBps, one
    );
  }

  /// @notice Exposes the terminal loss waterfall.
  /// @param recoveryAssets Actual recovery.
  /// @param debt Total receivable.
  /// @param fees Attributed fees inside debt.
  /// @param reserve Funded reserve.
  /// @return result Complete allocation.
  function waterfall(uint256 recoveryAssets, uint256 debt, uint256 fees, uint256 reserve)
    external
    pure
    returns (SettlementWaterfall memory result)
  {
    result = LibPositionRisk.settlementWaterfall(recoveryAssets, debt, fees, reserve);
  }
}
