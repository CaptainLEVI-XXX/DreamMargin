/** Credit constraints reported by the controller. */
export type CapKind = "position" | "outcome" | "market" | "global" | "utilization" | "vaultCash";

/** Remaining headroom under each cap, in collateral native units. */
export type CapHeadroom = Record<CapKind, bigint>;
