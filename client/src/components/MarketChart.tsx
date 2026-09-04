import { useState } from "react";
import { formatUnits } from "../domain/amounts";
import type { IndexPoint, IndexSeries } from "../data/priceFeed";
import { Value } from "./Value";

/**
 * The market chart. Design FS-1.
 *
 * Plots the underlying index price as candles, with the market's opening level
 * as a rule so distance to strike is legible at a glance. The index series is
 * used rather than the YES probability because the probability side carries a
 * handful of trades where this carries thousands of ticks, and a candlestick of
 * three isolated prints implies a trend those prints cannot support.
 *
 * The liquidation boundary is deliberately absent: it lives on the probability
 * axis in cents, and no fixed mapping exists from an underlying price to a
 * probability, so drawing it over a dollar series would be meaningless.
 */

type Props = {
  series: IndexSeries;
  strike: bigint | null;
  asset: string;
  height?: number;
};

const WIDTH = 720;
const PAD_TOP = 8;

type Scale = { x: (i: number) => number; y: (v: bigint) => number; bodyWidth: number };

function scaleFor(points: IndexPoint[], strike: bigint | null, height: number): Scale {
  let min = points.reduce((a, p) => (p.low < a ? p.low : a), points[0].low);
  let max = points.reduce((a, p) => (p.high > a ? p.high : a), points[0].high);

  // Keep the strike on canvas; a rule drawn off-screen tells the reader nothing.
  if (strike !== null) {
    if (strike < min) min = strike;
    if (strike > max) max = strike;
  }

  const span = max - min === 0n ? 1n : max - min;
  const pad = span / 20n;
  const lo = min - pad;
  const hi = max + pad;
  const range = hi - lo === 0n ? 1n : hi - lo;
  const plot = height - PAD_TOP * 2;

  return {
    // Scale to fixed point before the single float conversion, so full-magnitude
    // bigint prices never pass through a float.
    y: (v: bigint) => PAD_TOP + (Number(((hi - v) * 10_000n) / range) / 10_000) * plot,
    x: (i: number) => ((i + 0.5) / points.length) * WIDTH,
    bodyWidth: Math.max(1.5, (WIDTH / points.length) * 0.6),
  };
}

export function MarketChart({ series, strike, asset, height = 220 }: Props) {
  const [hover, setHover] = useState<number | null>(null);
  const { points, decimals } = series;

  if (points.length < 2) {
    return (
      <div className="dm-chart dm-chart-empty">
        <p>Not enough price history to chart yet.</p>
      </div>
    );
  }

  const s = scaleFor(points, strike, height);
  const active = hover === null ? points[points.length - 1] : points[hover];
  const aboveStrike = strike === null ? null : active.close >= strike;
  const fmt = (v: bigint) => formatUnits(v, decimals, 2);

  return (
    <figure className="dm-chart">
      <figcaption className="dm-chart-head">
        <span>
          {asset} <Value>{fmt(active.close)}</Value>
          {hover === null ? null : <span className="dm-chart-scrub"> at cursor</span>}
        </span>
        {strike === null ? null : (
          <span>
            Opening <Value>{fmt(strike)}</Value>{" "}
            <span className="dm-chart-verdict" data-above={aboveStrike === true}>
              {aboveStrike === true ? "above" : "below"}
            </span>
          </span>
        )}
      </figcaption>

      <svg
        viewBox={`0 0 ${WIDTH} ${height}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={
          strike === null
            ? `${asset} index price`
            : `${asset} index price, currently ${aboveStrike === true ? "above" : "below"} the opening level`
        }
        onMouseLeave={() => setHover(null)}
        onMouseMove={(event) => {
          const box = event.currentTarget.getBoundingClientRect();
          const ratio = (event.clientX - box.left) / box.width;
          const i = Math.floor(ratio * points.length);
          setHover(i < 0 ? 0 : i >= points.length ? points.length - 1 : i);
        }}
      >
        {strike === null ? null : (
          <line
            x1={0}
            x2={WIDTH}
            y1={s.y(strike)}
            y2={s.y(strike)}
            className="dm-chart-strike"
            strokeDasharray="4 4"
          />
        )}

        {points.map((p, i) => {
          const up = p.close >= p.open;
          const top = s.y(up ? p.close : p.open);
          const bottom = s.y(up ? p.open : p.close);
          return (
            <g key={String(p.time)} data-up={up} className="dm-candle">
              <line x1={s.x(i)} x2={s.x(i)} y1={s.y(p.high)} y2={s.y(p.low)} className="dm-wick" />
              <rect
                x={s.x(i) - s.bodyWidth / 2}
                y={top}
                width={s.bodyWidth}
                height={Math.max(1, bottom - top)}
                className="dm-body"
              />
            </g>
          );
        })}

        {hover === null ? null : (
          <line x1={s.x(hover)} x2={s.x(hover)} y1={0} y2={height} className="dm-chart-cursor" />
        )}
      </svg>

      <figcaption className="dm-chart-foot">
        <span>
          O <Value>{fmt(active.open)}</Value> H <Value>{fmt(active.high)}</Value> L{" "}
          <Value>{fmt(active.low)}</Value> C <Value>{fmt(active.close)}</Value>
        </span>
        <span>
          <Value>{active.count}</Value> ticks
        </span>
      </figcaption>
    </figure>
  );
}
