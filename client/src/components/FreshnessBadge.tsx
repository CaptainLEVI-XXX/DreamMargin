import { ageLabel, freshnessOf, type Freshness } from "../domain/freshness";
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
