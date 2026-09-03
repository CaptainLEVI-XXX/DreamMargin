/**
 * Available credit, and which cap is responsible for it.
 *
 * FS-3: on this deployment the per-position cap is 100 tUSDC and the global cap
 * 1,000 tUSDC, so a user hits a cap far more often than the leverage ceiling.
 * A blocked action must say which one bound it.
 */

export type CapKind = "position" | "outcome" | "market" | "global" | "utilization" | "vaultCash";

/** Remaining headroom under each cap, in collateral native units. */
export type CapHeadroom = Record<CapKind, bigint>;

export type CreditAvailability = {
  /** The smallest headroom, floored at zero. */
  available: bigint;
  /** Which cap produced it. */
  binding: CapKind;
  /** Plain-language explanation for the UI. */
  explanation: string;
};

const EXPLANATIONS: Record<CapKind, string> = {
  position: "This position has reached its individual credit limit",
  outcome: "This outcome has reached its credit limit",
  market: "This market has reached its credit limit",
  global: "The protocol has reached its overall credit limit",
  utilization: "The vault has reached its maximum utilization",
  vaultCash: "The vault has no available cash to lend right now",
};

const ORDER: readonly CapKind[] = [
  "position",
  "outcome",
  "market",
  "global",
  "utilization",
  "vaultCash",
];

/** Find the binding cap and the credit it allows. */
export function availableCredit(headroom: CapHeadroom): CreditAvailability {
  let binding: CapKind = ORDER[0];
  let smallest = headroom[binding];

  for (const kind of ORDER) {
    if (headroom[kind] < smallest) {
      smallest = headroom[kind];
      binding = kind;
    }
  }

  return {
    available: smallest < 0n ? 0n : smallest,
    binding,
    explanation: EXPLANATIONS[binding],
  };
}
