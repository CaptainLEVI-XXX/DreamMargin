import { formatUnits } from "../domain/amounts";
import type { IndexPoint, IndexSeries } from "../data/priceFeed";
import { Value } from "./Value";

/**
 * The builder chart. Design FS-1.
 *
 * One component, two configurations. Here it plots the underlying index price —
 * dense and streaming — with the market's opening level as a horizontal rule, so
 * distance to strike is legible at a glance. It answers: is the thing I am
 * betting on actually happening?
 *
 * The liquidation boundary is deliberately absent. It lives on the probability
 * axis in cents, and there is no fixed mapping from an underlying price to a YES
 * probability — the market decides that. Drawing "liquidation near 48c" over a
 * dollar series would be meaningless, so the position terminal uses the safety
 * buffer bar instead.
 *
 * Drawn as inline SVG rather than a charting library: the hairline dark system
 * needs no axis chrome, and this keeps the bundle free of a dependency whose
 * defaults would have to be fought.
 */

type Props = {
  series: IndexSeries;
  /** Index level at trading open, or null when unknown. */
  strike: bigint | null;
  asset: string;
  height?: number;
};

const WIDTH = 640;

function project(points: IndexPoint[], strike: bigint | null, height: number) {
  const lows = points.map((p) => p.low);
  const highs = points.map((p) => p.high);
  let min = lows.reduce((a, b) => (b < a ? b : a));
  let max = highs.reduce((a, b) => (b > a ? b : a));

  // Keep the strike on screen; a rule drawn off-canvas tells the user nothing.
  if (strike !== null) {
    if (strike < min) min = strike;
    if (strike > max) max = strike;
  }

  const span = max - min === 0n ? 1n : max - min;
  const pad = span / 20n;
  const lo = min - pad;
  const hi = max + pad;
  const range = hi - lo === 0n ? 1n : hi - lo;

  // Scale to a fixed-point integer before the single float conversion, so the
  // bigint prices never pass through a float at full magnitude.
  const y = (v: bigint) => {
    const scaled = ((hi - v) * 10_000n) / range;
    return (Number(scaled) / 10_000) * height;
  };
  const x = (i: number) => (points.length === 1 ? WIDTH : (i / (points.length - 1)) * WIDTH);

  return { x, y, lo, hi };
}

export function MarketChart({ series, strike, asset, height = 160 }: Props) {
  const { points, decimals } = series;

  if (points.length < 2) {
    return (
      <div className="dm-chart dm-chart-empty">
        <p>Not enough price history to chart yet.</p>
      </div>
    );
  }

  const { x, y } = project(points, strike, height);
  const path = points
    .map((p, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(p.close).toFixed(1)}`)
    .join(" ");
  const last = points[points.length - 1];
  const first = points[0];
  const up = last.close >= first.close;
  const aboveStrike = strike === null ? null : last.close >= strike;

  return (
    <figure className="dm-chart">
      <figcaption className="dm-chart-head">
        <span>
          {asset} index <Value>{formatUnits(last.close, decimals, 2)}</Value>
        </span>
        {strike === null ? null : (
          <span>
            Opening level <Value>{formatUnits(strike, decimals, 2)}</Value>
            {" · "}
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
            ? `${asset} index price over the trading window`
            : `${asset} index price, currently ${aboveStrike === true ? "above" : "below"} the opening level`
        }
      >
        {strike === null ? null : (
          <line
            x1={0}
            x2={WIDTH}
            y1={y(strike)}
            y2={y(strike)}
            className="dm-chart-strike"
            strokeDasharray="3 3"
          />
        )}
        <path d={path} className="dm-chart-line" data-up={up} fill="none" />
      </svg>

      <figcaption className="dm-chart-foot">
        <span>
          {points.length} buckets · {points.reduce((sum, p) => sum + p.count, 0)} ticks
        </span>
      </figcaption>
    </figure>
  );
}
