import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { TradeView } from "./TradeView";
import { SCENARIOS } from "../fixtures/scenarios";
import { EMPTY_BALANCES } from "../web3/tokens";
import { assertSingleAccentFill } from "../dev/accentGuard";
import type { BookLevel } from "../domain/bookQuote";

const ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678" as const;
const market = SCENARIOS.healthy.markets[0];
const vault = SCENARIOS.healthy.vault;
const book: { asks: BookLevel[]; bids: BookLevel[] } = {
  asks: [{ yesPrice: 983_000n, quantity: 100_000_000n }],
  bids: [{ yesPrice: 981_000n, quantity: 100_000_000n }],
};
const emptyVault = { ...vault, availableLiquidity: 0n };

function view(over: Partial<Parameters<typeof TradeView>[0]> = {}) {
  return (
    <TradeView
      market={market}
      protocol={SCENARIOS.healthy.protocol}
      vault={vault}
      balances={EMPTY_BALANCES}
      book={book}
      account={ACCOUNT}
      {...over}
    />
  );
}

async function selectTier(index: number) {
  await userEvent.click(screen.getAllByRole("radio")[index]);
}

describe("layout", () => {
  it("puts the question and chart alongside one action panel", () => {
    render(view());
    expect(screen.getByRole("heading", { name: /Will ETH close/ })).toBeVisible();
    expect(screen.getByLabelText("tUSDC amount")).toBeVisible();
  });

  it("offers useful ranges for a long-duration market", () => {
    render(view());
    const ranges = screen.getByRole("group", { name: "Chart range" });
    expect(ranges).toHaveTextContent("4H");
    expect(ranges).toHaveTextContent("10D");
    expect(ranges).toHaveTextContent("All");
  });

  it("shows a live market countdown beside the detail heading", () => {
    render(view());
    expect(screen.getByLabelText("Market time remaining")).toHaveTextContent(/closes in/i);
  });

  it("returns to the market list without using global navigation", async () => {
    const onBack = vi.fn();
    render(view({ onBack }));
    await userEvent.click(screen.getByRole("button", { name: /markets/i }));
    expect(onBack).toHaveBeenCalledOnce();
  });

  it("offers YES and NO as one selector, not two screens", () => {
    render(view());
    expect(screen.getByRole("button", { name: /^YES/ })).toBeVisible();
    expect(screen.getByRole("button", { name: /^NO/ })).toBeVisible();
  });

  it("shows executable buy and sell prices instead of only the midpoint", () => {
    render(
      view({
        market: { ...market, yesPrice: 500_000n },
        book: {
          asks: [{ yesPrice: 550_000n, quantity: 500_000_000n }],
          bids: [{ yesPrice: 450_000n, quantity: 500_000_000n }],
        },
      }),
    );
    expect(screen.getByRole("button", { name: /YESBuy 55.*Sell 45/i })).toBeVisible();
    expect(screen.getByRole("button", { name: /NOBuy 55.*Sell 45/i })).toBeVisible();
  });

  it("shows YES and NO as selected-versus-neutral, never green versus red", () => {
    const { container } = render(view());
    const yes = screen.getByRole("button", { name: /^YES/ });
    expect(yes).toHaveAttribute("data-selected");
    // Neither carries a value-movement class.
    expect(container.querySelector(".dm-side-option.dm-up")).toBeNull();
  });

  it("switches side on click", async () => {
    render(view());
    await userEvent.click(screen.getByRole("button", { name: /^NO/ }));
    expect(screen.getByRole("button", { name: /^NO/ })).toHaveAttribute("data-selected");
  });
});

describe("the tier row is the action", () => {
  it("labels 1x as a plain purchase", async () => {
    render(view());
    await selectTier(0);
    expect(screen.getByRole("button", { name: /^Buy YES$/ })).toBeVisible();
    expect(screen.getByText(/without borrowing/i)).toBeVisible();
  });

  it("keeps the action focused on the position rather than its funding math", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1.25x" }));
    expect(screen.getByRole("button", { name: "Open YES position" })).toBeVisible();
    expect(screen.getByText(/without calculating the borrowing/i)).toBeVisible();
  });

  it("shows clean achievable choices and an honest market-specific maximum", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "Max 1.44x" }));
    expect(screen.getByRole("radio", { name: "Max 1.44x" })).toBeChecked();
    expect(screen.queryByRole("radio", { name: "2x" })).toBeNull();
  });

  it("defaults to the lowest useful tier, never the maximum", () => {
    render(view());
    const options = screen.getAllByRole("radio");
    expect(options[1]).toBeChecked();
    expect(options[options.length - 1]).not.toBeChecked();
  });

  it("does not expose wallet-step counting as product copy", async () => {
    render(view());
    await selectTier(0);
    expect(screen.queryByText(/wallet confirmations?/i)).toBeNull();
    await selectTier(2);
    expect(screen.queryByText(/wallet confirmations?/i)).toBeNull();
  });
});

describe("book depth", () => {
  it("says nothing when the book covers the size", () => {
    render(view());
    expect(screen.queryByText(/minting the rest/i)).toBeNull();
  });

  it("never invents shares beyond visible order-book depth", async () => {
    render(view({ book: { asks: [{ yesPrice: 983_000n, quantity: 1_000_000n }], bids: [] } }));
    await selectTier(0);
    const summary = screen.getByText("You receive").closest("dl");
    expect(summary).not.toBeNull();
    expect(within(summary!).getByText("1")).toBeVisible();
    expect(screen.queryByText(/mint/i)).toBeNull();
  });

  it("says plainly when the selected side has no liquidity", () => {
    render(view({ book: { asks: [], bids: [] } }));
    expect(screen.getByRole("button", { name: /buy yes/i })).toBeDisabled();
    expect(screen.getByText(/order book has no liquidity/i)).toBeVisible();
  });
});

describe("honest pricing", () => {
  it("shows the value actually available from the entered wallet budget", async () => {
    render(view());
    await selectTier(0);
    expect(screen.getByText("Position exposure")).toBeVisible();
    expect(screen.getAllByText("49.99 tUSDC").length).toBeGreaterThan(0);
  });

  it("refuses to present a stale oracle's mark as a real value", () => {
    // §4.5 keeps market price and risk mark distinct; echoing one as the other
    // would invent the distinction the rule exists to preserve.
    render(view({ market: { ...market, oracleStale: true } }));
    expect(screen.getByText(/unavailable while risk data is stale/i)).toBeVisible();
  });

  it("says a market has never traded rather than showing a midpoint as fact", () => {
    render(view({ market: { ...market, priceKnown: false } }));
    expect(screen.getByText(/no trades yet/i)).toBeVisible();
  });
});

describe("vault cash", () => {
  it("blocks leverage and offers to supply when the vault is empty", async () => {
    render(view({ vault: emptyVault }));
    await userEvent.click(screen.getByRole("radio", { name: "1.25x" }));
    expect(screen.getByRole("button", { name: /open .* position/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /supply the vault/i })).toBeVisible();
  });

  it("still allows a spot purchase with an empty vault", async () => {
    render(view({ vault: emptyVault }));
    await selectTier(0);
    expect(screen.getByRole("button", { name: /^Buy YES$/ })).toBeEnabled();
  });
});

describe("direct collateral opening", () => {
  it("turns a wallet budget and clean leverage choice into a position", async () => {
    render(
      view({
        market: { ...market, yesPrice: 500_000n, riskMark: 450_000n },
        book: {
          asks: [{ yesPrice: 550_000n, quantity: 500_000_000n }],
          bids: [{ yesPrice: 450_000n, quantity: 500_000_000n }],
        },
      }),
    );
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));

    expect(screen.getByLabelText("tUSDC amount")).toHaveValue("50");
    expect(screen.getByText("134.35")).toBeVisible();
    expect(screen.getByText("134.35 tUSDC")).toBeVisible();
    expect(screen.getByText("73.89 tUSDC")).toBeVisible();
    expect(screen.getByText("49.25 tUSDC")).toBeVisible();
    expect(screen.getByText("35.82 tUSDC")).toBeVisible();
    await userEvent.click(screen.getByText("Order details"));
    expect(screen.getByText("49.99 tUSDC")).toBeVisible();
    expect(screen.getAllByText("1.5x").length).toBeGreaterThanOrEqual(2);
    expect(screen.getByRole("button", { name: "Open YES position" })).toBeVisible();
  });

  it("does not add a pre-buy even when the wallet already holds outcomes", async () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 100_000_000n } }));
    await userEvent.click(screen.getByRole("radio", { name: "1.25x" }));
    // The controller purchases the exact target from tUSDC; held outcomes are untouched.
    expect(screen.getByRole("button", { name: /open .* position/i })).toBeVisible();
  });

  it("shows only the wallet input and resulting position", () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 100_000_000n } }));
    expect(screen.getByLabelText("tUSDC amount")).toBeVisible();
    expect(screen.getByText("You receive")).toBeVisible();
    expect(screen.getByText("Position exposure")).toBeVisible();
    expect(screen.getByText("If closed now")).toBeVisible();
    expect(screen.getByText("Maximum payout")).toBeVisible();
    expect(screen.getByText("Estimated leverage")).toBeVisible();
    expect(screen.queryByText("Borrowed from vault")).toBeNull();
    expect(screen.queryByText("Conservative value")).toBeNull();
  });

  it("shows what the wallet holds on both sides", () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 240_000_000n, no: 10_000_000n } }));
    expect(screen.getByText("You hold")).toBeVisible();
  });

  it("keeps intermediate lending calculations out of the trade panel", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "Max 1.44x" }));
    const summary = screen.getByText("Estimated leverage").closest("dl");
    expect(summary).not.toBeNull();
    expect(within(summary!).queryByText(/debt|risk equity|price premium|vault credit/i)).toBeNull();
  });
});

describe("guards", () => {
  it("requires a wallet before acting", () => {
    render(view({ account: null }));
    expect(screen.getByRole("button", { name: "Open YES position" })).toBeDisabled();
    expect(screen.getAllByText(/connect a wallet to continue/i).length).toBeGreaterThan(0);
  });

  it("previews honest leverage before a wallet connects", () => {
    render(view({ account: null }));
    expect(screen.getByRole("radio", { name: "Max 1.44x" })).toBeVisible();
  });

  it("keeps one solid violet object", () => {
    const { container } = render(view());
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });

  it("opens no dialog", () => {
    render(view());
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
