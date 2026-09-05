import type { IndexPoint } from "../data/priceFeed";

/**
 * Recent movement of the underlying, in a single row's worth of space.
 *
 * The market list is for scanning, so this answers one question — which way has
 * it been going — and leaves price discovery to the market page. Coloured by
 * net direction over the window, which §18.3 permits for value movement.
 */
export function Sparkline({
  points,
  width = 72,
  height = 20,
}: {
  points: readonly IndexPoint[];
  width?: number;
  height?: number;
}) {
  if (points.length < 2) return <span className="dm-spark-empty">—</span>;

  const closes = points.map((p) => p.close);
  const min = closes.reduce((a, b) => (b < a ? b : a));
  const max = closes.reduce((a, b) => (b > a ? b : a));
  const range = max - min === 0n ? 1n : max - min;

  const d = closes
    .map((c, i) => {
      const x = (i / (closes.length - 1)) * width;
      // Fixed point before the single float conversion, so full-magnitude
      // prices never pass through a float.
      const y = height - (Number(((c - min) * 10_000n) / range) / 10_000) * height;
      return `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");

  const up = closes[closes.length - 1] >= closes[0];

  return (
    <svg
      className="dm-spark"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      data-up={up}
      aria-hidden="true"
    >
      <path d={d} fill="none" />
    </svg>
  );
}
