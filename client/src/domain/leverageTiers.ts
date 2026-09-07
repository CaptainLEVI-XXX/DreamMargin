import { formatUnits, mulDivDown } from "./amounts";

const BPS = 10_000n;

/** Render a multiple in the brand's lowercase suffix form: 1x, 1.25x, 2x. */
export function formatMultiple(leverageBps: bigint): string {
  return `${formatUnits(leverageBps, 4, 2)}x`;
}

/** Entry position value divided by the wallet payment, rounded down for display. */
export function effectiveLeverageBps(positionValue: bigint, walletPayment: bigint): bigint {
  if (positionValue === 0n || walletPayment === 0n) return BPS;
  const leverage = mulDivDown(positionValue, BPS, walletPayment);
  return leverage < BPS ? BPS : leverage;
}
