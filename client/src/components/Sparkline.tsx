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
  if (points.length < 2) return <span className="dm-spark-empty">Price history unavailable</span>;

  const closes = points.map((p) => p.close);
  const min = closes.reduce((a, b) => (b < a ? b : a));
  const max = closes.reduce((a, b) => (b > a ? b : a));
  const range = max - min === 0n ? 1n : max - min;

  const projected = closes.map((c, i) => {
    const x = (i / (closes.length - 1)) * width;
    // Fixed point before the single float conversion, so full-magnitude
    // prices never pass through a float.
    const y = height - (Number(((c - min) * 10_000n) / range) / 10_000) * height;
    return { x, y };
  });
  const d = projected
    .map(({ x, y }, i) => `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`)
    .join(" ");
  const area = `${d} L${width},${height} L0,${height} Z`;
  const last = projected[projected.length - 1];

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
      <path className="dm-spark-area" d={area} />
      <path className="dm-spark-line" d={d} fill="none" />
      <circle className="dm-spark-dot" cx={last.x} cy={last.y} r="2.5" />
    </svg>
  );
}
