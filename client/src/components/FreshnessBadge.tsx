import { ageLabel, freshnessOf, type Freshness } from "../domain/freshness";
import type { OracleSnapshot } from "../web3/reads";
import { Value } from "./Value";

/**
 * Oracle freshness, stated plainly.
 *
 * Initial maturity needs three observations at least 30 seconds apart. Once a
 * generation is mature, anyone can record a fresh sample; the trade screen
 * offers that permissionless action when a quiet market becomes stale.
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
