import { render, screen } from "@testing-library/react";
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

describe("layout", () => {
  it("puts the question and chart alongside one action panel", () => {
    render(view());
    expect(screen.getByRole("heading", { name: /Will ETH close/ })).toBeVisible();
    expect(screen.getByLabelText("Position size in shares")).toBeVisible();
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
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByRole("button", { name: /^Buy 5 YES$/ })).toBeVisible();
    expect(screen.getByText(/normal DreamDEX purchase with no borrowing/i)).toBeVisible();
  });

  it("labels a leveraged tier with the multiple", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByRole("button", { name: /Open 1\.5x position/ })).toBeVisible();
  });

  it("shows borrowing only above 1x", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.queryByText("Vault credit")).toBeNull();
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByText("Vault credit")).toBeVisible();
  });

  it("defaults to the lowest useful tier, never the maximum", () => {
    render(view());
    expect(screen.getByRole("radio", { name: "1.25x" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "2x" })).not.toBeChecked();
  });

  it("does not expose wallet-step counting as product copy", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.queryByText(/wallet confirmations?/i)).toBeNull();
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.queryByText(/wallet confirmations?/i)).toBeNull();
  });
});

describe("book depth and minting", () => {
  it("says nothing when the book covers the size", () => {
    render(view());
    expect(screen.queryByText(/minting the rest/i)).toBeNull();
  });

  it("explains the mint fallback and that it returns the other outcome", async () => {
    render(view({ book: { asks: [{ yesPrice: 983_000n, quantity: 1_000_000n }], bids: [] } }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByText(/minting the remaining/i)).toBeVisible();
    expect(screen.getByText(/NO shares/)).toBeVisible();
  });

  it("states amounts in shares, never native units", async () => {
    render(view({ book: { asks: [{ yesPrice: 983_000n, quantity: 1_000_000n }], bids: [] } }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    // "1 of 5", not "1000000 of 5000000".
    const note = screen.getByText(/book covers 1 of 5/i);
    expect(note).not.toHaveTextContent(/\d{7,}/);
  });

  it("says plainly when the book is empty rather than implying partial cover", async () => {
    render(view({ book: { asks: [], bids: [] } }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByText(/order book has no YES for sale/i)).toBeVisible();
  });
});

describe("honest pricing", () => {
  it("shows the effective price paid, not the market price, when minting", async () => {
    // An empty book means every share is minted at one whole unit, so the
    // market price is not what is being paid.
    render(view({ book: { asks: [], bids: [] } }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByText("Average price")).toBeVisible();
    expect(screen.getByText("100¢")).toBeVisible();
  });

  it("shows the book price when the book fills the order", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByText("98.3¢")).toBeVisible();
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
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByRole("button", { name: /open 1\.5x position/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /supply the vault/i })).toBeVisible();
  });

  it("still allows a spot purchase with an empty vault", async () => {
    render(view({ vault: emptyVault }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByRole("button", { name: /^Buy 5 YES$/ })).toBeEnabled();
  });
});

describe("direct collateral opening", () => {
  it("does not add a pre-buy even when the wallet already holds outcomes", async () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 100_000_000n } }));
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    // The controller purchases the exact target from tUSDC; held outcomes are untouched.
    expect(screen.getByRole("button", { name: /open 1\.5x position/i })).toBeVisible();
  });

  it("separates bounded owner tUSDC from vault credit and exposure", () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 100_000_000n } }));
    expect(screen.getByText("Expected from wallet")).toBeVisible();
    expect(screen.getByText("Authorized maximum")).toBeVisible();
    expect(screen.getByText("Vault credit")).toBeVisible();
    expect(screen.getByText("Position exposure")).toBeVisible();
  });

  it("shows what the wallet holds on both sides", () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 240_000_000n, no: 10_000_000n } }));
    expect(screen.getByText("You hold")).toBeVisible();
  });
});

describe("guards", () => {
  it("requires a wallet before acting", () => {
    render(view({ account: null }));
    expect(screen.getByRole("button", { name: /position|buy/i })).toBeDisabled();
    expect(screen.getAllByText(/connect a wallet to continue/i).length).toBeGreaterThan(0);
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
