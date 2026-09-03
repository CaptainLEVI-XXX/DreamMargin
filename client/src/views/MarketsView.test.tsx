import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { MarketsView } from "./MarketsView";
import { SCENARIOS } from "../fixtures/scenarios";
import { assertSingleAccentFill } from "../dev/accentGuard";

describe("MarketsView", () => {
  it("shows the full market question", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    expect(screen.getByText(/Will ETH close at or above its opening price/)).toBeVisible();
  });

  it("separates owned outcomes from other markets", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    expect(screen.getByRole("heading", { name: /your eligible outcomes/i })).toBeVisible();
    expect(screen.getByRole("heading", { name: /other eligible markets/i })).toBeVisible();
  });

  it("shows prices in cents, not as probabilities", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    expect(screen.getAllByText(/62¢/).length).toBeGreaterThan(0);
    expect(screen.queryByText(/62% chance/)).toBeNull();
  });

  it("names the cap binding available credit", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    expect(screen.getAllByText(/individual credit limit/i).length).toBeGreaterThan(0);
  });

  it("marks every position as isolated", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    expect(screen.getAllByText(/isolated position/i).length).toBeGreaterThan(0);
  });

  it("offers no leverage action when the user owns nothing", () => {
    render(<MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />);
    const other = screen.getByTestId("other-markets");
    expect(within(other).queryByRole("button", { name: /use .* shares/i })).toBeNull();
  });

  it("disables leverage with an explanation when paused", () => {
    render(<MarketsView snapshot={SCENARIOS.paused} onOpenBuilder={() => {}} />);
    const cta = screen.getAllByRole("button", { name: /use yes shares/i })[0];
    expect(cta).toBeDisabled();
    expect(screen.getAllByText(/New risk is paused/i).length).toBeGreaterThan(0);
  });

  it("keeps exactly one solid violet object", () => {
    const { container } = render(
      <MarketsView snapshot={SCENARIOS.healthy} onOpenBuilder={() => {}} />,
    );
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });
});
