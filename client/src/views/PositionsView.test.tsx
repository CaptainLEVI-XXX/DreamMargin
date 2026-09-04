import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PositionsView } from "./PositionsView";
import { SCENARIOS } from "../fixtures/scenarios";
import { assertSingleAccentFill } from "../dev/accentGuard";

const ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678" as const;

describe("PositionsView", () => {
  it("states isolation and never a portfolio health factor", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={ACCOUNT} />);
    expect(screen.getAllByText(/isolated/i).length).toBeGreaterThan(0);
    expect(screen.queryByText(/portfolio health/i)).toBeNull();
  });

  it("shows the safety buffer with a text state", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={ACCOUNT} />);
    expect(screen.getByRole("meter")).toBeVisible();
    expect(screen.getByText("Safe")).toBeVisible();
  });

  it("labels an at-risk position with text, not colour alone", () => {
    render(<PositionsView snapshot={SCENARIOS.atRisk} account={ACCOUNT} />);
    expect(screen.getByText("At risk")).toBeVisible();
  });

  it("makes repay the primary action on an at-risk position", () => {
    const { container } = render(<PositionsView snapshot={SCENARIOS.atRisk} account={ACCOUNT} />);
    expect(container.querySelector("[data-accent-fill]")).toHaveTextContent(/repay/i);
  });

  it("keeps repay available when paused", () => {
    render(<PositionsView snapshot={SCENARIOS.paused} account={ACCOUNT} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeEnabled();
  });

  it("keeps repay and add collateral available on a stale oracle", () => {
    render(<PositionsView snapshot={SCENARIOS.staleOracle} account={ACCOUNT} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Add collateral" })).toBeEnabled();
  });

  it("offers settlement on a resolved position", () => {
    render(<PositionsView snapshot={SCENARIOS.resolved} account={ACCOUNT} />);
    expect(screen.getByRole("button", { name: "Settle position" })).toBeVisible();
  });

  it("distinguishes market value from conservative risk value per §4.5", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={ACCOUNT} />);
    expect(screen.getByText(/outcome market value/i)).toBeVisible();
    expect(screen.getByText(/conservative risk value/i)).toBeVisible();
  });

  it("keeps exactly one solid violet object", () => {
    const { container } = render(<PositionsView snapshot={SCENARIOS.healthy} account={ACCOUNT} />);
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });
});

describe("actions need a real, owned position", () => {
  it("disables every action and says why when disconnected", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={null} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Add collateral" })).toBeDisabled();
    expect(screen.getAllByText(/connect a wallet to act on this position/i).length).toBeGreaterThan(
      0,
    );
  });

  it("explains that a wallet is needed before positions can be shown", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={null} />);
    expect(screen.getByText(/connect a wallet to see your positions/i)).toBeVisible();
  });

  it("says it is reading rather than showing invented positions", () => {
    render(
      <PositionsView
        snapshot={{ ...SCENARIOS.healthy, positions: [] }}
        account={ACCOUNT}
        loading
      />,
    );
    expect(screen.getByText(/reading your positions from the chain/i)).toBeVisible();
  });

  it("never invents a position when the wallet has none", () => {
    render(<PositionsView snapshot={{ ...SCENARIOS.healthy, positions: [] }} account={ACCOUNT} />);
    expect(screen.queryByRole("button", { name: "Repay" })).toBeNull();
  });

  it("tells a connected wallet with no positions what to do next", () => {
    render(<PositionsView snapshot={{ ...SCENARIOS.healthy, positions: [] }} account={ACCOUNT} />);
    expect(screen.getByText(/no open positions/i)).toBeVisible();
    expect(screen.getByText(/choose a multiple above 1x/i)).toBeVisible();
  });

  it("enables actions on a real position with a connected wallet", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} account={ACCOUNT} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Add collateral" })).toBeEnabled();
    expect(screen.getByRole("button", { name: /repay and withdraw/i })).toBeEnabled();
  });
});
