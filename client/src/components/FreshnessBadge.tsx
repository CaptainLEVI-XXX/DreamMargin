import type { OracleSnapshot } from "../web3/reads";
import { Value } from "./Value";

/**
 * Oracle freshness, stated plainly.
 *
 * Design D-8: clearing staleness needs at least three observations at least 30
 * seconds apart, so a one-click "refresh" button cannot do it and is not
 * offered. Freshness is a keeper's job (`script/observe-shannon.sh`); the
 * client's job is to say honestly how old the data is and what that blocks.
 *
 * frontend-spec §16.2: show observation age and whether data is live, delayed,
 * or stale — never a generic animated dot with no timestamp.
 */

export type Freshness = "live" | "delayed" | "stale" | "building";

export function freshnessOf(snapshot: OracleSnapshot): Freshness {
  if (snapshot.stale) return "stale";
  if (snapshot.mark === null) return "building";
  return snapshot.updatedSecondsAgo > 60 ? "delayed" : "live";
}

function ageLabel(seconds: number): string {
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3_600)}h ago`;
}

const WORDING: Record<Freshness, string> = {
  live: "Live",
  delayed: "Delayed",
  stale: "Risk data stale",
  building: "Risk history building",
};

export function FreshnessBadge({ snapshot }: { snapshot: OracleSnapshot }) {
  const state = freshnessOf(snapshot);

  return (
    <div className="dm-freshness" data-state={state}>
      <span className="dm-freshness-state">{WORDING[state]}</span>
      <span>
        Updated <Value>{ageLabel(snapshot.updatedSecondsAgo)}</Value>
      </span>
      <span>
        Observations{" "}
        <Value>
          {snapshot.cardinality}/{snapshot.maxObservations}
        </Value>
      </span>
      {snapshot.reason === undefined ? null : (
        <span className="dm-freshness-reason">{snapshot.reason}</span>
      )}
    </div>
  );
}
