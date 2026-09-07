import type { OracleSnapshot } from "../web3/reads";

/**
 * Oracle freshness classification. frontend-spec §16.2 requires data to be
 * labelled live, delayed, or stale with an observation age — never a generic
 * animated dot with no timestamp.
 */
export type Freshness = "live" | "delayed" | "stale" | "building";

export function freshnessOf(snapshot: OracleSnapshot): Freshness {
  if (snapshot.stale) return "stale";
  // A missing mark on fresh observations means the ring has not matured yet,
  // which is a different problem with a different remedy.
  if (snapshot.mark === null) return "building";
  return snapshot.updatedSecondsAgo > 60 ? "delayed" : "live";
}

/** Human age for a badge: seconds, minutes, then hours. */
export function ageLabel(seconds: number): string {
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3_600)}h ago`;
}
