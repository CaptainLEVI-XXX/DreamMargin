/**
 * Risk presentation. frontend-spec §8.4 requires that colour is never the only
 * signal, so `RiskState` makes `label` and `icon` mandatory: a colour-only risk
 * display cannot be constructed from this type.
 *
 * Thresholds are display-only. Contract liquidation is decided on-chain from the
 * conservative risk mark, never from this classification.
 */

export type RiskLevel = "comfortable" | "watch" | "at-risk" | "liquidatable";

export type RiskState = {
  /** Machine-readable band, used to select a token. */
  level: RiskLevel;
  /** Human wording shown beside the colour. Never empty. */
  label: string;
  /** Text glyph shown beside the colour. Never empty. */
  icon: string;
};

const COMFORTABLE_MIN_BPS = 2500n;
const WATCH_MIN_BPS = 1000n;

/** Classify a safety buffer, expressed in basis points, into a display state. */
export function riskStateFromBufferBps(bufferBps: bigint): RiskState {
  if (bufferBps <= 0n) return { level: "liquidatable", label: "Liquidatable", icon: "×" };
  if (bufferBps >= COMFORTABLE_MIN_BPS) return { level: "comfortable", label: "Safe", icon: "✓" };
  if (bufferBps >= WATCH_MIN_BPS) return { level: "watch", label: "Watch", icon: "!" };
  return { level: "at-risk", label: "At risk", icon: "!" };
}
