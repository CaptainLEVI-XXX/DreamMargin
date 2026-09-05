import { useState } from "react";
import { Countdown } from "../components/Countdown";
import { Sparkline } from "../components/Sparkline";
import { Value } from "../components/Value";
import { formatCents, formatUnits } from "../domain/amounts";
import type { IndexPoint } from "../data/priceFeed";
import type { AppSnapshot, MarketView } from "../domain/models";

type Props = {
  snapshot: AppSnapshot;
  onOpenBuilder: (market: MarketView) => void;
  loading?: boolean;
  error?: string;
  /** Recent underlying movement, keyed by asset ticker. */
  sparks?: Record<string, IndexPoint[]>;
};

type SortKey = "ends" | "interval" | "price" | "asset";

/** How often this series rolls. */
function intervalLabel(m: MarketView): string {
  const s = m.expiry - m.tradingStart;
  if (s >= 86_400n) return `${s / 86_400n}d`;
  if (s >= 3_600n) return `${s / 3_600n}h`;
  return `${s / 60n}m`;
}

function intervalSeconds(m: MarketView): bigint {
  return m.expiry - m.tradingStart;
}

/**
 * The market list: one row per market, dense enough to scan.
 *
 * The list is sorted by what resolves first and makes duration visible. Only
 * the dedicated long-lived BTC and ETH generations are shown.
 */
export function MarketsView({ snapshot, onOpenBuilder, loading, error, sparks = {} }: Props) {
  const [sort, setSort] = useState<SortKey>("ends");

  const rows = [...snapshot.markets].sort((a, b) => {
    if (sort === "asset") return a.asset.localeCompare(b.asset);
    if (sort === "interval") return Number(intervalSeconds(a) - intervalSeconds(b));
    if (sort === "price") return Number(b.yesPrice - a.yesPrice);
    return Number(a.expiry - b.expiry);
  });

  // Every header renders the same element whether or not it sorts, so one rule
  // governs the row instead of two competing treatments.
  const header = (label: string, key?: SortKey, numeric = false) => (
    <th scope="col" className={numeric ? "dm-num" : undefined}>
      {key === undefined ? (
        <span>{label}</span>
      ) : (
        <button
          type="button"
          onClick={() => setSort(key)}
          data-active={sort === key ? "" : undefined}
        >
          {label}
        </button>
      )}
    </th>
  );

  return (
    <div className="dm-markets">
      <h1>Markets</h1>
      <p className="dm-markets-lede">
        Buy an outcome, or use shares you hold as equity for an isolated leveraged position.
      </p>

      {loading === true ? <p className="dm-empty-note">Finding markets…</p> : null}
      {error === undefined ? null : (
        <p className="dm-empty-note">Could not read the market contracts. {error}</p>
      )}
      {loading !== true && error === undefined && rows.length === 0 ? (
        <p className="dm-empty-note">No markets are trading right now.</p>
      ) : null}

      {rows.length === 0 ? null : (
        <table className="dm-table">
          <colgroup>
            {/* Fixed widths: a ticking countdown must not shift the columns
                beside it every second. */}
            <col className="dm-col-market" />
            <col className="dm-col-narrow" />
            <col className="dm-col-time" />
            <col className="dm-col-price" />
            <col className="dm-col-price" />
            <col className="dm-col-spark" />
            <col className="dm-col-tag" />
            <col className="dm-col-hold" />
            <col className="dm-col-action" />
          </colgroup>
          <thead>
            <tr>
              {header("Market", "asset")}
              {header("Interval", "interval")}
              {header("Ends in", "ends", true)}
              {header("YES", "price", true)}
              {header("NO", undefined, true)}
              {header("Last 20m")}
              {header("Leverage")}
              {header("You hold", undefined, true)}
              {header("", undefined, true)}
            </tr>
          </thead>
          <tbody>
            {rows.map((m) => {
              const leveraged = m.maxLeverageBps > 10_000n;
              const held = m.ownedYes + m.ownedNo;
              return (
                <tr key={`${m.key.pool}-${m.key.outcomeId}`}>
                  <th scope="row">
                    <span className="dm-row-asset">{m.asset}</span>
                    <span className="dm-row-question">{m.question}</span>
                  </th>
                  <td>
                    <Value>{intervalLabel(m)}</Value>
                  </td>
                  <td className="dm-num">
                    <Countdown expiry={m.expiry} />
                  </td>
                  <td className="dm-num">
                    <Value>{formatCents(m.yesPrice, m.oneCollateral)}</Value>
                  </td>
                  <td className="dm-num">
                    <Value>{formatCents(m.oneCollateral - m.yesPrice, m.oneCollateral)}</Value>
                  </td>
                  <td className="dm-cell-spark">
                    <Sparkline points={sparks[m.asset] ?? []} />
                  </td>
                  <td>
                    {leveraged ? (
                      <span className="dm-tag" data-on="">
                        up to {Number(m.maxLeverageBps) / 10_000}x
                      </span>
                    ) : (
                      <span className="dm-tag">buy only</span>
                    )}
                  </td>
                  <td className="dm-num">
                    {held === 0n ? (
                      <span className="dm-spark-empty">—</span>
                    ) : (
                      <Value>{formatUnits(held, m.collateralDecimals, 2)}</Value>
                    )}
                  </td>
                  <td>
                    <button
                      type="button"
                      className="dm-row-action"
                      onClick={() => onOpenBuilder(m)}
                    >
                      Trade
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
