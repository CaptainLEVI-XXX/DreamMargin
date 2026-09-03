import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
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
    expect(screen.getByLabelText("Shares")).toBeVisible();
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
    expect(screen.getByText(/spot purchase, no borrowing/i)).toBeVisible();
  });

  it("labels a leveraged tier with the multiple", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByRole("button", { name: /Buy 5 YES at 1\.5x/ })).toBeVisible();
  });

  it("shows borrowing only above 1x", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.queryByText("Borrowed")).toBeNull();
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByText("Borrowed")).toBeVisible();
  });

  it("defaults to the lowest useful tier, never the maximum", () => {
    render(view());
    expect(screen.getByRole("radio", { name: "1.25x" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "2x" })).not.toBeChecked();
  });

  it("counts every confirmation across buy and open", async () => {
    render(view());
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByText("2 wallet confirmations")).toBeVisible();
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByText("4 wallet confirmations")).toBeVisible();
  });
});

describe("book depth and minting", () => {
  it("says nothing when the book covers the size", () => {
    render(view());
    expect(screen.queryByText(/minting the rest/i)).toBeNull();
  });

  it("explains the mint fallback and that it returns the other outcome", () => {
    render(view({ book: { asks: [{ yesPrice: 983_000n, quantity: 1_000_000n }], bids: [] } }));
    expect(screen.getByText(/minting the rest/i)).toBeVisible();
    expect(screen.getByText(/NO shares/)).toBeVisible();
  });
});

describe("vault cash", () => {
  it("blocks leverage and offers to supply when the vault is empty", async () => {
    render(view({ vault: emptyVault }));
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    expect(screen.getByRole("button", { name: /buy 5 yes at 1\.5x/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /supply the vault/i })).toBeVisible();
  });

  it("still allows a spot purchase with an empty vault", async () => {
    render(view({ vault: emptyVault }));
    await userEvent.click(screen.getByRole("radio", { name: "1x" }));
    expect(screen.getByRole("button", { name: /^Buy 5 YES$/ })).toBeEnabled();
  });
});

describe("held shares", () => {
  it("skips buying when the wallet already holds enough", async () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 100_000_000n } }));
    await userEvent.click(screen.getByRole("radio", { name: "1.5x" }));
    // Only the open remains: approve outcome id, then open.
    expect(screen.getByText("2 wallet confirmations")).toBeVisible();
  });

  it("shows what the wallet holds on both sides", () => {
    render(view({ balances: { ...EMPTY_BALANCES, yes: 240_000_000n, no: 10_000_000n } }));
    expect(screen.getByText("You hold")).toBeVisible();
  });
});

describe("guards", () => {
  it("requires a wallet before acting", () => {
    render(view({ account: null }));
    expect(screen.getByRole("button", { name: /buy/i })).toBeDisabled();
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
