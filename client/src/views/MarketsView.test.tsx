import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { MarketsView } from "./MarketsView";
import { SCENARIOS } from "../fixtures/scenarios";
import { assertSingleAccentFill } from "../dev/accentGuard";
import type { MarketView } from "../domain/models";

const base = SCENARIOS.healthy;
const ONE = 1_000_000n;

/** A 1-minute market: too short for leverage, so it must read as buy-only. */
const oneMinute: MarketView = {
  ...base.markets[0],
  asset: "BTC",
  question: "BTC closes at or above its opening price",
  tradingStart: 1_788_400_000n,
  expiry: 1_788_400_060n,
  maxLeverageBps: 10_000n,
  ownedYes: 0n,
  ownedNo: 0n,
  key: { ...base.markets[0].key, outcomeId: 99n },
};

const daily: MarketView = {
  ...base.markets[0],
  asset: "ETH",
  tradingStart: 1_788_400_000n,
  expiry: 1_788_486_400n,
  maxLeverageBps: 20_000n,
  ownedYes: 240n * ONE,
};

function view(markets: MarketView[], over: Partial<Parameters<typeof MarketsView>[0]> = {}) {
  return <MarketsView snapshot={{ ...base, markets }} onOpenBuilder={() => {}} {...over} />;
}

describe("market list", () => {
  it("shows one row per live market", () => {
    render(view([oneMinute, daily]));
    expect(screen.getAllByRole("row")).toHaveLength(3); // header + two markets
  });

  it("makes the roll interval a first-class column", () => {
    render(view([oneMinute, daily]));
    expect(screen.getByText("1m")).toBeVisible();
    expect(screen.getByText("1d")).toBeVisible();
  });

  it("shows both outcome prices in cents, not as probabilities", () => {
    render(view([daily]));
    expect(screen.getAllByText(/62¢/).length).toBeGreaterThan(0);
    expect(screen.queryByText(/62% chance/)).toBeNull();
  });

  it("marks a market with no registered generation as buy only", () => {
    render(view([oneMinute]));
    expect(screen.getByText("buy only")).toBeVisible();
  });

  it("shows the leverage ceiling where one exists", () => {
    render(view([daily]));
    expect(screen.getByText(/up to 2x/i)).toBeVisible();
  });

  it("shows a holding only where the wallet has one", () => {
    render(view([oneMinute, daily]));
    const rows = screen.getAllByRole("row");
    expect(within(rows[2]).getByText("240")).toBeVisible();
  });

  it("orders by what resolves soonest by default", () => {
    render(view([daily, oneMinute]));
    const rows = screen.getAllByRole("row");
    expect(within(rows[1]).getByText("1m")).toBeVisible();
  });

  it("re-sorts on a column header", async () => {
    render(view([oneMinute, daily]));
    await userEvent.click(screen.getByRole("button", { name: "Market" }));
    const rows = screen.getAllByRole("row");
    expect(within(rows[1]).getByText("BTC")).toBeVisible();
  });

  it("opens the trade panel from a row", async () => {
    const onOpenBuilder = vi.fn();
    render(view([daily], { onOpenBuilder }));
    await userEvent.click(screen.getByRole("button", { name: "Trade" }));
    expect(onOpenBuilder).toHaveBeenCalledWith(daily);
  });
});

describe("states", () => {
  it("says it is searching rather than showing an empty table", () => {
    render(view([], { loading: true }));
    expect(screen.getByText(/finding markets/i)).toBeVisible();
    expect(screen.queryByRole("table")).toBeNull();
  });

  it("surfaces a chain-read failure instead of implying no markets exist", () => {
    render(view([], { error: "upstream request timeout" }));
    expect(screen.getByText(/could not read the market contracts/i)).toBeVisible();
  });

  it("says plainly when nothing is trading", () => {
    render(view([]));
    expect(screen.getByText(/no markets are trading right now/i)).toBeVisible();
  });
});

describe("brand", () => {
  it("keeps borrow headroom off the list, where it would read as a limit", () => {
    render(view([daily]));
    expect(screen.queryByText(/available to borrow/i)).toBeNull();
    expect(screen.queryByText(/credit limit/i)).toBeNull();
  });

  it("uses no solid violet fill in a scanning surface", () => {
    const { container } = render(view([oneMinute, daily]));
    expect(() => assertSingleAccentFill(container)).not.toThrow();
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});

describe("alignment", () => {
  it("gives every header the same element, so one rule governs the row", () => {
    render(view([daily]));
    const headers = screen.getAllByRole("columnheader");
    // Sortable headers hold a button; the rest hold a span. Both are styled by
    // the same selector pair, so no header is left on default th styling.
    for (const th of headers) {
      expect(th.querySelector("button, span")).not.toBeNull();
    }
  });

  it("fixes column widths so a ticking countdown cannot resize its neighbours", () => {
    const { container } = render(view([daily]));
    expect(container.querySelector("colgroup")).not.toBeNull();
    expect(container.querySelectorAll("col")).toHaveLength(
      screen.getAllByRole("columnheader").length,
    );
  });

  it("right-aligns numeric headers with their cells", () => {
    render(view([daily]));
    for (const label of ["Ends in", "YES", "NO", "You hold"]) {
      const th = screen.getByText(label).closest("th");
      expect(th?.className).toContain("dm-num");
    }
  });

  it("keeps the countdown one fixed-width format", () => {
    const soon: MarketView = {
      ...daily,
      expiry: BigInt(Math.floor(Date.now() / 1000)) + 3_600n,
    };
    render(view([soon]));
    // Always hh:mm:ss, never switching to a "1d 02h" form of a different width.
    expect(screen.getByText(/^\d{2}:\d{2}:\d{2}$/)).toBeVisible();
  });

  it("says trading is closed rather than counting past zero", () => {
    render(view([daily]));
    expect(screen.getByText(/trading closed/i)).toBeVisible();
  });
});
