import { mulDivDown, mulDivUp, quantizeDown, quantizeUp } from "./amounts";
import type { PositionView } from "./models";

const BPS = 10_000n;
const REPAY_BUFFER_BPS = 100n;

/** Allow one percent for debt-index movement between the read, approval, and action. */
export function repaymentLimit(debtAssets: bigint): bigint {
  if (debtAssets === 0n) return 0n;
  const buffer = mulDivUp(debtAssets, REPAY_BUFFER_BPS, BPS);
  return debtAssets + (buffer === 0n ? 1n : buffer);
}

export type DeleveragePlan =
  | {
      ready: true;
      sharesToSell: bigint;
      minCollateralOut: bigint;
      limitPrice: bigint;
    }
  | { ready: false; reason: string };

export type FullClosePlan =
  | {
      ready: true;
      minCollateralOut: bigint;
      maxRepayAssets: bigint;
      limitPrice: bigint;
      estimatedOwnerAssets: bigint;
    }
  | { ready: false; reason: string };

/** Quote a fill-or-kill sale of every position share into tUSDC. */
export function planFullCloseToCollateral(position: PositionView): FullClosePlan {
  const { market } = position;
  const levels = position.outcomeIndex === 0 ? market.book?.yesBids : market.book?.noBids;
  if (levels === undefined || levels.length === 0) {
    return { ready: false, reason: "No exit liquidity is available for this outcome" };
  }

  let remaining = position.shares;
  let proceeds = 0n;
  let worstSidePrice = 0n;
  for (const level of levels) {
    if (remaining === 0n) break;
    const take = level.quantity < remaining ? level.quantity : remaining;
    if (take === 0n) continue;
    proceeds += mulDivDown(take, level.price, market.oneCollateral);
    remaining -= take;
    worstSidePrice = level.price;
  }
  if (remaining !== 0n || worstSidePrice === 0n) {
    return { ready: false, reason: "The order book cannot sell the entire position" };
  }

  const bufferedDebt = repaymentLimit(position.debtAssets);
  return {
    ready: true,
    minCollateralOut: proceeds,
    maxRepayAssets: bufferedDebt > proceeds ? bufferedDebt - proceeds : 0n,
    limitPrice:
      position.outcomeIndex === 0 ? worstSidePrice : market.oneCollateral - worstSidePrice,
    estimatedOwnerAssets: proceeds > position.debtAssets ? proceeds - position.debtAssets : 0n,
  };
}

/**
 * Sell enough book-backed shares to clear the current debt plus its movement
 * buffer. Clearing debt avoids the protocol's forbidden sub-minimum remainder.
 */
export function planDebtClearingDeleverage(
  position: PositionView,
  lotSize = 1_000n,
): DeleveragePlan {
  if (position.debtAssets === 0n) return { ready: false, reason: "This position has no debt" };

  const { market } = position;
  const levels = position.outcomeIndex === 0 ? market.book?.yesBids : market.book?.noBids;
  if (levels === undefined || levels.length === 0) {
    return { ready: false, reason: "No exit liquidity is available for this outcome" };
  }

  const target = repaymentLimit(position.debtAssets);
  let proceeds = 0n;
  let sharesToSell = 0n;
  let worstSidePrice = 0n;

  for (const level of levels) {
    if (proceeds >= target || sharesToSell >= position.shares) break;
    if (level.price === 0n) continue;

    const positionRemaining = position.shares - sharesToSell;
    const levelShares = quantizeDown(level.quantity, lotSize);
    const available = levelShares < positionRemaining ? levelShares : positionRemaining;
    if (available === 0n) continue;

    const assetsRemaining = target - proceeds;
    const sharesNeeded = quantizeUp(
      mulDivUp(assetsRemaining, market.oneCollateral, level.price),
      lotSize,
    );
    const take = sharesNeeded < available ? sharesNeeded : available;
    sharesToSell += take;
    proceeds += mulDivDown(take, level.price, market.oneCollateral);
    worstSidePrice = level.price;
  }

  if (proceeds < target || worstSidePrice === 0n) {
    return {
      ready: false,
      reason: "The current order book cannot safely clear this position's debt",
    };
  }

  return {
    ready: true,
    sharesToSell,
    // The execution buffer covers debt movement; this is the minimum economic result.
    minCollateralOut: position.debtAssets,
    limitPrice:
      position.outcomeIndex === 0 ? worstSidePrice : market.oneCollateral - worstSidePrice,
  };
}
