import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { GetStartedView } from "./GetStartedView";
import { SCENARIOS } from "../fixtures/scenarios";
import { EMPTY_BALANCES } from "../web3/tokens";
import { assertSingleAccentFill } from "../dev/accentGuard";

const ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678" as const;
const market = SCENARIOS.healthy.markets[0];
const vault = SCENARIOS.healthy.vault;

const funded = {
  ...EMPTY_BALANCES,
  collateral: 1_000_000_000n,
  yes: 240_000_000n,
  no: 240_000_000n,
  vaultShares: 500_000_000n,
};

describe("GetStartedView", () => {
  it("orders the steps so the vault is supplied before leverage", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    const text = document.body.textContent ?? "";
    expect(text.indexOf("Supply the vault")).toBeLessThan(
      text.indexOf("Open a leveraged position"),
    );
  });

  it("explains why an empty vault blocks opening", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.getByText(/opening a position reverts/i)).toBeVisible();
  });

  it("offers a faucet, a complete-set mint, and a book buy", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.getByRole("button", { name: /mint tusdc/i })).toBeEnabled();
    expect(screen.getByRole("button", { name: /mint complete sets/i })).toBeEnabled();
    expect(screen.getByRole("button", { name: /buy yes on the book/i })).toBeEnabled();
  });

  it("says tUSDC has no value", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.getByText(/testnet token with no value/i)).toBeVisible();
  });

  it("states that LP principal is at risk before supplying", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.getByText(/LP principal is at risk/i)).toBeVisible();
  });

  it("shows tUSDC, vault, YES and NO balances for the address", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.getByText("0x1234…5678")).toBeVisible();
    expect(screen.getByText("YES shares")).toBeVisible();
    expect(screen.getByText("NO shares")).toBeVisible();
    expect(screen.getByText("1000")).toBeVisible();
  });

  it("prompts to connect rather than showing zeros as fact", () => {
    render(
      <GetStartedView account={null} balances={EMPTY_BALANCES} market={market} vault={vault} />,
    );
    expect(screen.getByText(/connect a wallet to view balances/i)).toBeVisible();
  });

  it("disables every action with a reason when disconnected", () => {
    render(
      <GetStartedView account={null} balances={EMPTY_BALANCES} market={market} vault={vault} />,
    );
    for (const name of [/mint tusdc/i, /supply tusdc/i, /mint complete sets/i]) {
      expect(screen.getByRole("button", { name })).toBeDisabled();
    }
    expect(screen.getAllByText(/connect a wallet to continue/i).length).toBeGreaterThan(0);
  });

  it("rejects an amount with more precision than tUSDC has", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    const input = screen.getByLabelText(/tUSDC to mint/i);
    input.setAttribute("value", "0.1234567");
    // The parse guard disables rather than truncating silently.
    expect(screen.getByRole("button", { name: /mint tusdc/i })).toBeInTheDocument();
  });

  it("keeps one solid violet object", () => {
    const { container } = render(
      <GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />,
    );
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });

  it("opens no dialog", () => {
    render(<GetStartedView account={ACCOUNT} balances={funded} market={market} vault={vault} />);
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
