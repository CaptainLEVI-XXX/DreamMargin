import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { PositionsView } from "./PositionsView";
import { SCENARIOS } from "../fixtures/scenarios";
import { assertSingleAccentFill } from "../dev/accentGuard";

describe("PositionsView", () => {
  it("states isolation and never a portfolio health factor", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} />);
    expect(screen.getAllByText(/isolated/i).length).toBeGreaterThan(0);
    expect(screen.queryByText(/portfolio health/i)).toBeNull();
  });

  it("shows the safety buffer with a text state", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} />);
    expect(screen.getByRole("meter")).toBeVisible();
    expect(screen.getByText("Safe")).toBeVisible();
  });

  it("labels an at-risk position with text, not colour alone", () => {
    render(<PositionsView snapshot={SCENARIOS.atRisk} />);
    expect(screen.getByText("At risk")).toBeVisible();
  });

  it("makes repay the primary action on an at-risk position", () => {
    const { container } = render(<PositionsView snapshot={SCENARIOS.atRisk} />);
    expect(container.querySelector("[data-accent-fill]")).toHaveTextContent(/repay/i);
  });

  it("keeps repay available when paused", () => {
    render(<PositionsView snapshot={SCENARIOS.paused} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeEnabled();
  });

  it("keeps repay and add collateral available on a stale oracle", () => {
    render(<PositionsView snapshot={SCENARIOS.staleOracle} />);
    expect(screen.getByRole("button", { name: "Repay" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Add collateral" })).toBeEnabled();
  });

  it("offers settlement on a resolved position", () => {
    render(<PositionsView snapshot={SCENARIOS.resolved} />);
    expect(screen.getByRole("button", { name: "Settle position" })).toBeVisible();
  });

  it("distinguishes market value from conservative risk value per §4.5", () => {
    render(<PositionsView snapshot={SCENARIOS.healthy} />);
    expect(screen.getByText(/outcome market value/i)).toBeVisible();
    expect(screen.getByText(/conservative risk value/i)).toBeVisible();
  });

  it("keeps exactly one solid violet object", () => {
    const { container } = render(<PositionsView snapshot={SCENARIOS.healthy} />);
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });
});
