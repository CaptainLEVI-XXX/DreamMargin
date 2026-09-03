import { formatUnits } from "./amounts";

/**
 * Leverage tiers. FS-2: the ladder is generated from the contract's current
 * maximum, so an unsupported tier is absent rather than shown as an enticing
 * disabled target (frontend-spec §18.5). Today the deployed maximum is 2.0x.
 */

const BPS = 10_000n;
const STEP = 2_500n;

/** Quarter-step tiers from 1x up to the contract maximum, inclusive. */
export function tiersFor(maxLeverageBps: bigint): bigint[] {
  const tiers: bigint[] = [];
  for (let tier = BPS; tier <= maxLeverageBps; tier += STEP) tiers.push(tier);
  return tiers.length === 0 ? [BPS] : tiers;
}

/** Render a multiple in the brand's lowercase suffix form: 1x, 1.25x, 2x. */
export function formatMultiple(leverageBps: bigint): string {
  return `${formatUnits(leverageBps, 4)}x`;
}

/**
 * The default selection. Never the maximum (§8.3): the lowest tier above spot,
 * or spot itself when no leverage is available.
 */
export function defaultTier(tiers: readonly bigint[]): bigint {
  return tiers.length > 1 ? tiers[1] : tiers[0];
}
