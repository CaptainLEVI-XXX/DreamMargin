import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MarketChart } from "./MarketChart";
import { strikeAt, type IndexSeries } from "../data/priceFeed";

const E18 = 10n ** 18n;

/**
 * lightweight-charts draws to a real canvas, which jsdom does not implement.
 * The chart body is exercised in the browser; these tests cover the parts that
 * decide what a reader is told: the header, the strike verdict, and that the
 * liquidation boundary never appears on this axis.
 */
vi.mock("lightweight-charts", () => {
  const series = {
    setData: vi.fn(),
    createPriceLine: vi.fn(() => ({})),
    removePriceLine: vi.fn(),
  };
  return {
    createChart: vi.fn(() => ({
      addSeries: vi.fn(() => series),
      subscribeCrosshairMove: vi.fn(),
      applyOptions: vi.fn(),
      timeScale: vi.fn(() => ({ fitContent: vi.fn() })),
      remove: vi.fn(),
    })),
    CandlestickSeries: {},
    ColorType: { Solid: "solid" },
    CrosshairMode: { Normal: 0 },
    LineStyle: { Dotted: 1, Dashed: 2 },
  };
});

function series(closes: number[], start = 1_788_464_000n): IndexSeries {
  return {
    points: closes.map((c, i) => ({
      time: start + BigInt(i) * 60n,
      open: BigInt(c) * E18,
      high: BigInt(c + 1) * E18,
      low: BigInt(c - 1) * E18,
      close: BigInt(c) * E18,
      count: 30,
    })),
    decimals: 18,
    spot: BigInt(closes.at(-1) ?? 0) * E18,
    updatedAtMs: 1_788_464_000_000n,
  };
}

describe("MarketChart", () => {
  it("names the asset and shows its latest price", () => {
    render(<MarketChart series={series([2500, 2510, 2512])} strike={null} asset="ETH" />);
    expect(screen.getByText("ETH")).toBeVisible();
    expect(screen.getByText("2512")).toBeVisible();
  });

  it("says price is above the opening level", () => {
    render(<MarketChart series={series([2500, 2520])} strike={2505n * E18} asset="ETH" />);
    expect(screen.getByText("above")).toBeVisible();
  });

  it("says price is below the opening level", () => {
    render(<MarketChart series={series([2520, 2500])} strike={2515n * E18} asset="ETH" />);
    expect(screen.getByText("below")).toBeVisible();
  });

  it("omits the opening level when it is unknown", () => {
    render(<MarketChart series={series([2500, 2510])} strike={null} asset="ETH" />);
    expect(screen.queryByText(/opening/i)).toBeNull();
  });

  it("never shows the liquidation boundary, which lives on the probability axis", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510])} strike={2505n * E18} asset="ETH" />,
    );
    expect(container.textContent).not.toMatch(/liquidation/i);
    expect(container.textContent).not.toMatch(/¢/);
  });

  it("tells the reader the chart can be zoomed and panned", () => {
    render(<MarketChart series={series([2500, 2510])} strike={null} asset="ETH" />);
    expect(screen.getByText(/scroll to zoom, drag to pan/i)).toBeVisible();
  });

  it("renders an empty series without throwing", () => {
    expect(() =>
      render(<MarketChart series={series([])} strike={null} asset="ETH" />),
    ).not.toThrow();
  });

  it("carries no solid violet fill", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510])} strike={null} asset="ETH" />,
    );
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});

describe("strikeAt", () => {
  it("takes the first bucket at or after trading opened", () => {
    expect(strikeAt(series([2500, 2510, 2520], 1_000n), 1_060n)).toBe(2510n * E18);
  });

  it("returns null when the series ends before trading opened", () => {
    expect(strikeAt(series([2500, 2510], 5_000n), 9_999n)).toBeNull();
  });
});
