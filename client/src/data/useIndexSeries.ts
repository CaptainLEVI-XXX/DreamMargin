import { useEffect, useState } from "react";
import { fetchIndexSeries, strikeAt, type IndexSeries, type Resolution } from "./priceFeed";

export type IndexSeriesState =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "ready"; series: IndexSeries; strike: bigint | null };

/**
 * Load the underlying index series for a market's trading window.
 *
 * The quote is pinned to USDC: the feed holds stale USDT history for the same
 * bases, and matching both double-counts buckets, which breaks a chart that
 * needs strictly ascending unique timestamps.
 *
 * State carries the request it belongs to rather than being reset inside the
 * effect, so switching markets renders as loading without a synchronous
 * setState triggering a cascading render.
 */
export function useIndexSeries(
  base: string,
  tradingStart: bigint,
  resolution: Resolution = "M1",
  limit = 240,
): IndexSeriesState {
  const key = `${base}|${tradingStart}|${resolution}|${limit}`;
  const [entry, setEntry] = useState<{ key: string; state: IndexSeriesState }>({
    key,
    state: { kind: "loading" },
  });

  useEffect(() => {
    let cancelled = false;

    void fetchIndexSeries(base, "USDC", resolution, limit)
      .then((series) => {
        if (cancelled) return;
        setEntry({ key, state: { kind: "ready", series, strike: strikeAt(series, tradingStart) } });
      })
      .catch(() => {
        if (!cancelled) setEntry({ key, state: { kind: "error" } });
      });

    return () => {
      cancelled = true;
    };
  }, [key, base, tradingStart, resolution, limit]);

  // A result from a superseded request is ignored rather than shown.
  return entry.key === key ? entry.state : { kind: "loading" };
}
