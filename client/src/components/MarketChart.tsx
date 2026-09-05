import { useEffect, useRef, useState } from "react";
import {
  CandlestickSeries,
  ColorType,
  CrosshairMode,
  LineStyle,
  createChart,
  type CandlestickData,
  type IChartApi,
  type ISeriesApi,
  type Time,
} from "lightweight-charts";
import { formatUnits } from "../domain/amounts";
import type { IndexSeries } from "../data/priceFeed";
import { Value } from "./Value";

/**
 * The market chart. Design FS-1.
 *
 * Plots the underlying index price with the market's opening level as a rule,
 * so distance to strike is legible at a glance. The index is used rather than
 * the YES probability because the probability side carries a handful of trades
 * where this carries thousands of ticks per hour, and a candlestick of three
 * isolated prints implies a trend those prints cannot support.
 *
 * The liquidation boundary is deliberately absent: it lives on the probability
 * axis in cents, and no fixed mapping exists from an underlying price to a
 * probability, so drawing it over a dollar series would mislead.
 *
 * Built on TradingView's lightweight-charts for real zoom, pan and crosshair
 * behaviour. It is themed down to the brand tokens rather than left on its
 * defaults: no grid, hairline borders, and the two signal colours §18.3 already
 * reserves for value movement.
 */

type Props = {
  series: IndexSeries;
  strike: bigint | null;
  asset: string;
  height?: number;
};

/** Read a brand token so the chart cannot drift from the rest of the UI. */
function token(name: string, fallback: string): string {
  if (typeof window === "undefined") return fallback;
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v === "" ? fallback : v;
}

/** Scale fixed-point prices to the floats the chart library needs. */
function toFloat(value: bigint, decimals: number): number {
  return Number((value * 10_000n) / 10n ** BigInt(decimals)) / 10_000;
}

export function MarketChart({ series, strike, asset, height = 260 }: Props) {
  const host = useRef<HTMLDivElement | null>(null);
  const chart = useRef<IChartApi | null>(null);
  const candles = useRef<ISeriesApi<"Candlestick"> | null>(null);
  const [readout, setReadout] = useState<CandlestickData<Time> | null>(null);

  useEffect(() => {
    if (host.current === null) return;

    const up = token("--dm-up", "#00d68f");
    const down = token("--dm-down", "#f6465d");
    const line = token("--dm-line", "#26262a");
    const text = token("--dm-text", "#a8aaad");

    const api = createChart(host.current, {
      height,
      layout: {
        background: { type: ColorType.Solid, color: "transparent" },
        textColor: text,
        fontFamily: token("--dm-font-mono", "monospace"),
        fontSize: 11,
        attributionLogo: false,
      },
      // Hairlines only: §18.1 draws on the ground rather than in a panel.
      grid: { vertLines: { visible: false }, horzLines: { color: line, style: LineStyle.Dotted } },
      rightPriceScale: { borderColor: line },
      timeScale: { borderColor: line, timeVisible: true, secondsVisible: false },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { color: text, width: 1, style: LineStyle.Dotted, labelBackgroundColor: line },
        horzLine: { color: text, width: 1, style: LineStyle.Dotted, labelBackgroundColor: line },
      },
      handleScroll: true,
      handleScale: true,
    });

    const s = api.addSeries(CandlestickSeries, {
      upColor: up,
      downColor: down,
      borderUpColor: up,
      borderDownColor: down,
      wickUpColor: up,
      wickDownColor: down,
    });

    api.subscribeCrosshairMove((param) => {
      const point = param.seriesData.get(s) as CandlestickData<Time> | undefined;
      setReadout(point ?? null);
    });

    const resize = () => {
      if (host.current !== null) api.applyOptions({ width: host.current.clientWidth });
    };
    resize();
    window.addEventListener("resize", resize);

    chart.current = api;
    candles.current = s;

    return () => {
      window.removeEventListener("resize", resize);
      api.remove();
      chart.current = null;
      candles.current = null;
    };
  }, [height]);

  useEffect(() => {
    const s = candles.current;
    if (s === null) return;

    s.setData(
      series.points.map((p) => ({
        time: Number(p.time) as Time,
        open: toFloat(p.open, series.decimals),
        high: toFloat(p.high, series.decimals),
        low: toFloat(p.low, series.decimals),
        close: toFloat(p.close, series.decimals),
      })),
    );

    chart.current?.timeScale().fitContent();
  }, [series]);

  useEffect(() => {
    const s = candles.current;
    if (s === null || strike === null) return;

    const priceLine = s.createPriceLine({
      price: toFloat(strike, series.decimals),
      color: token("--dm-text", "#a8aaad"),
      lineWidth: 1,
      lineStyle: LineStyle.Dashed,
      axisLabelVisible: true,
      title: "open",
    });

    return () => s.removePriceLine(priceLine);
  }, [strike, series.decimals]);

  const last = series.points.at(-1);
  const shown = readout ?? null;
  const aboveStrike = strike === null || last === undefined ? null : last.close >= strike;

  return (
    <figure className="dm-chart">
      <figcaption className="dm-chart-head">
        <span>
          {asset}{" "}
          <Value>
            {shown === null
              ? last === undefined
                ? "—"
                : formatUnits(last.close, series.decimals, 2)
              : shown.close.toFixed(2)}
          </Value>
        </span>
        {strike === null ? null : (
          <span>
            Opening <Value>{formatUnits(strike, series.decimals, 2)}</Value>{" "}
            <span className="dm-chart-verdict" data-above={aboveStrike === true}>
              {aboveStrike === true ? "above" : "below"}
            </span>
          </span>
        )}
      </figcaption>

      <div ref={host} className="dm-chart-canvas" />

      <figcaption className="dm-chart-foot">
        {shown === null ? (
          <span>Scroll to zoom, drag to pan</span>
        ) : (
          <span>
            O <Value>{shown.open.toFixed(2)}</Value> H <Value>{shown.high.toFixed(2)}</Value> L{" "}
            <Value>{shown.low.toFixed(2)}</Value> C <Value>{shown.close.toFixed(2)}</Value>
          </span>
        )}
      </figcaption>
    </figure>
  );
}
