import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { assertSingleAccentFill } from "../dev/accentGuard";
import type { IndexPoint } from "../data/priceFeed";
import type { MarketView } from "../domain/models";
import { SCENARIOS } from "../fixtures/scenarios";
import { MarketsView } from "./MarketsView";

const base = SCENARIOS.healthy;
const ONE = 1_000_000n;

const btc: MarketView = {
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

const eth: MarketView = {
  ...base.markets[0],
  asset: "ETH",
  tradingStart: 1_788_400_000n,
  expiry: 1_788_486_400n,
  maxLeverageBps: 20_000n,
  ownedYes: 240n * ONE,
};

const points: IndexPoint[] = [
  { time: 1n, open: 100n, high: 101n, low: 99n, close: 100n, count: 2 },
  { time: 2n, open: 100n, high: 104n, low: 100n, close: 103n, count: 3 },
];

function view(markets: MarketView[], over: Partial<Parameters<typeof MarketsView>[0]> = {}) {
  return <MarketsView snapshot={{ ...base, markets }} onOpenBuilder={() => {}} {...over} />;
}

describe("market cards", () => {
  it("renders one navigable card for each supported market", () => {
    render(view([eth, btc]));
    expect(screen.getByRole("button", { name: /open BTC market/i })).toBeVisible();
    expect(screen.getByRole("button", { name: /open ETH market/i })).toBeVisible();
    expect(screen.getByText("2 live")).toBeVisible();
  });

  it("puts the underlying graph inside each market card", () => {
    const { container } = render(view([btc, eth], { sparks: { BTC: points, ETH: points } }));
    expect(container.querySelectorAll(".dm-market-card .dm-spark")).toHaveLength(2);
    expect(screen.getAllByText(/underlying · last 20m/i)).toHaveLength(2);
  });

  it("shows both outcomes, duration, leverage, and wallet holdings", () => {
    render(view([btc, eth]));
    const btcCard = screen.getByRole("button", { name: /open BTC market/i });
    const ethCard = screen.getByRole("button", { name: /open ETH market/i });
    expect(within(btcCard).getByText("1 minute market")).toBeVisible();
    expect(within(btcCard).getByText("buy only")).toBeVisible();
    expect(within(ethCard).getByText("1 day market")).toBeVisible();
    expect(within(ethCard).getByText(/leverage available/i)).toBeVisible();
    expect(within(ethCard).getByText("240 shares held")).toBeVisible();
    expect(within(ethCard).getByText("YES")).toBeVisible();
    expect(within(ethCard).getByText("NO")).toBeVisible();
  });

  it("labels executable buy and sell prices instead of presenting a midpoint as tradable", () => {
    const priced = {
      ...eth,
      book: {
        yesBids: [{ price: 495_000n, quantity: 500n * ONE }],
        yesAsks: [{ price: 505_000n, quantity: 500n * ONE }],
        noBids: [{ price: 495_000n, quantity: 500n * ONE }],
        noAsks: [{ price: 505_000n, quantity: 500n * ONE }],
      },
    };
    render(view([priced]));
    const card = screen.getByRole("button", { name: /open ETH market/i });
    expect(within(card).getAllByText("50.5¢")).toHaveLength(2);
    expect(within(card).getAllByText("Sell 49.5¢")).toHaveLength(2);
  });

  it("opens the detail page by clicking anywhere on the card", async () => {
    const onOpenBuilder = vi.fn();
    render(view([eth], { onOpenBuilder }));
    await userEvent.click(screen.getByRole("button", { name: /open ETH market/i }));
    expect(onOpenBuilder).toHaveBeenCalledWith(eth);
  });

  it("keeps the card surface neutral instead of filling it violet", () => {
    const { container } = render(view([btc, eth]));
    expect(() => assertSingleAccentFill(container)).not.toThrow();
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});

describe("market states", () => {
  it("shows loading, read failure, and empty states honestly", () => {
    const { rerender } = render(view([], { loading: true }));
    expect(screen.getByText(/finding markets/i)).toBeVisible();

    rerender(view([], { error: "upstream request timeout" }));
    expect(screen.getByText(/could not read the market contracts/i)).toBeVisible();

    rerender(view([]));
    expect(screen.getByText(/no markets are trading right now/i)).toBeVisible();
  });

  it("says trading is closed rather than counting past zero", () => {
    render(view([eth]));
    expect(screen.getByText(/trading closed/i)).toBeVisible();
  });
});
