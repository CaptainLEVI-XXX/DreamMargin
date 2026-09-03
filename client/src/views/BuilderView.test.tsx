import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { BuilderView } from "./BuilderView";
import { SCENARIOS } from "../fixtures/scenarios";

const market = SCENARIOS.healthy.markets[0];

describe("BuilderView", () => {
  it("shows the consequences of leverage, not just the inputs", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/you commit/i)).toBeVisible();
    expect(screen.getByText(/borrowed/i)).toBeVisible();
    expect(screen.getByText(/effective leverage/i)).toBeVisible();
  });

  it("labels the action with the actual intent, never Continue", () => {
    const { container } = render(
      <BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />,
    );
    expect(container.querySelector("[data-accent-fill]")).toHaveTextContent(/add 1\.25x leverage/i);
    expect(screen.queryByRole("button", { name: /^continue$/i })).toBeNull();
    expect(screen.queryByRole("button", { name: /^review/i })).toBeNull();
  });

  it("defaults to the lowest useful tier, never the maximum", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByRole("radio", { name: "1.25x" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "2x" })).not.toBeChecked();
  });

  it("discloses the wallet confirmation count before the action", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/wallet confirmation/i)).toBeVisible();
  });

  it("names what is at risk", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/at risk/i)).toBeVisible();
  });

  it("keeps market price, risk mark, and exit value distinct", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/market price/i)).toBeVisible();
    expect(screen.getByText(/risk mark/i)).toBeVisible();
    expect(screen.getByText(/estimated exit value/i)).toBeVisible();
  });

  it("disables opening with an explanation when paused", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.paused.protocol} onBack={() => {}} />);
    expect(screen.getByRole("button", { name: /add .* leverage/i })).toBeDisabled();
    expect(screen.getByText(/New risk is paused/i)).toBeVisible();
  });

  it("has no separate review modal", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
