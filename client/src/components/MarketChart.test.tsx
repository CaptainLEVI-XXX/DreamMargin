import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MarketChart } from "./MarketChart";
import { strikeAt, type IndexSeries } from "../data/priceFeed";

const E18 = 10n ** 18n;

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
    spot: BigInt(closes[closes.length - 1]) * E18,
    updatedAtMs: 1_788_464_000_000n,
  };
}

describe("MarketChart", () => {
  it("says so rather than drawing a misleading line when history is thin", () => {
    render(<MarketChart series={series([2500])} strike={null} asset="ETH" />);
    expect(screen.getByText(/not enough price history/i)).toBeVisible();
  });

  it("plots one candle per bucket with the asset named", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510, 2512])} strike={null} asset="ETH" />,
    );
    expect(screen.getByText("ETH")).toBeVisible();
    expect(container.querySelectorAll(".dm-candle")).toHaveLength(3);
  });

  it("colours each candle by its own direction, not the series trend", () => {
    const s = series([2500, 2510, 2505]);
    // Force a down candle: close below open on the last bucket.
    s.points[2] = { ...s.points[2], open: 2520n * E18, close: 2505n * E18 };
    const { container } = render(<MarketChart series={s} strike={null} asset="ETH" />);
    const candles = container.querySelectorAll(".dm-candle");
    expect(candles[2].getAttribute("data-up")).toBe("false");
  });

  it("shows OHLC and tick count for the newest bucket by default", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510])} strike={null} asset="ETH" />,
    );
    const foot = container.querySelector(".dm-chart-foot")?.textContent ?? "";
    expect(foot).toMatch(/O\s*2510/);
    expect(foot).toMatch(/C\s*2510/);
    expect(foot).toMatch(/ticks/);
  });

  it("scrubs to the hovered candle", async () => {
    const { container } = render(
      <MarketChart series={series([2500, 2600, 2700])} strike={null} asset="ETH" />,
    );
    const svg = container.querySelector("svg") as SVGElement;
    svg.getBoundingClientRect = () => ({ left: 0, width: 300, top: 0, height: 220 }) as DOMRect;
    fireEvent.mouseMove(svg, { clientX: 10 });
    expect(screen.getByText(/at cursor/i)).toBeVisible();
    fireEvent.mouseLeave(svg);
    expect(screen.queryByText(/at cursor/i)).toBeNull();
  });

  it("draws the opening level and says which side price is on", () => {
    const s = series([2500, 2510, 2520]);
    render(<MarketChart series={s} strike={2505n * E18} asset="ETH" />);
    expect(screen.getByText(/opening/i)).toBeVisible();
    expect(screen.getByText("above")).toBeVisible();
  });

  it("reports being below the opening level", () => {
    const s = series([2520, 2510, 2500]);
    render(<MarketChart series={s} strike={2515n * E18} asset="ETH" />);
    expect(screen.getByText("below")).toBeVisible();
  });

  it("omits the strike rule entirely when the level is unknown", () => {
    const { container } = render(
      <MarketChart series={series([1, 2, 3])} strike={null} asset="ETH" />,
    );
    expect(container.querySelector(".dm-chart-strike")).toBeNull();
  });

  it("never draws the liquidation boundary, which lives on the probability axis", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510])} strike={2505n * E18} asset="ETH" />,
    );
    expect(container.textContent).not.toMatch(/liquidation/i);
    expect(container.textContent).not.toMatch(/¢/);
  });

  it("describes itself for assistive technology", () => {
    render(<MarketChart series={series([2500, 2520])} strike={2510n * E18} asset="ETH" />);
    expect(screen.getByRole("img")).toHaveAccessibleName(/above the opening level/i);
  });

  it("keeps the strike on canvas when it sits outside the price range", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2510])} strike={9_000n * E18} asset="ETH" height={100} />,
    );
    const line = container.querySelector(".dm-chart-strike");
    const y = Number(line?.getAttribute("y1"));
    expect(y).toBeGreaterThanOrEqual(0);
    expect(y).toBeLessThanOrEqual(100);
  });

  it("survives a flat series without dividing by zero", () => {
    const { container } = render(
      <MarketChart series={series([2500, 2500, 2500])} strike={2500n * E18} asset="ETH" />,
    );
    for (const rect of container.querySelectorAll(".dm-body")) {
      expect(rect.getAttribute("y")).not.toMatch(/NaN|Infinity/);
      expect(rect.getAttribute("height")).not.toMatch(/NaN|Infinity/);
    }
  });

  it("carries no solid violet fill", () => {
    const { container } = render(<MarketChart series={series([1, 2])} strike={null} asset="ETH" />);
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});

describe("strikeAt", () => {
  it("takes the first bucket at or after trading opened", () => {
    const s = series([2500, 2510, 2520], 1_000n);
    expect(strikeAt(s, 1_060n)).toBe(2510n * E18);
  });

  it("returns null when the series starts after trading opened", () => {
    const s = series([2500, 2510], 5_000n);
    expect(strikeAt(s, 1_000n)).toBe(2500n * E18);
    expect(strikeAt(s, 9_999n)).toBeNull();
  });
});
