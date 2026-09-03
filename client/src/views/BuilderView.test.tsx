import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
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

describe("BuilderView transaction intent", () => {
  it("discloses two wallet confirmations when an approval is needed", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText("2 wallet confirmations")).toBeVisible();
  });

  it("drops to one confirmation when the allowance already suffices", () => {
    render(
      <BuilderView
        market={market}
        protocol={SCENARIOS.healthy.protocol}
        onBack={() => {}}
        outcomeAllowance={market.ownedYes}
      />,
    );
    expect(screen.getByText("1 wallet confirmation")).toBeVisible();
  });

  it("promises one confirmation on a batching wallet", () => {
    render(
      <BuilderView
        market={market}
        protocol={SCENARIOS.healthy.protocol}
        onBack={() => {}}
        capabilities={{ atomicBatch: true }}
      />,
    );
    expect(screen.getByText("1 wallet confirmation")).toBeVisible();
  });

  it("shows the exact-id approval scope, not a global operator grant", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/only, outcome id/i)).toBeVisible();
  });

  it("shows the minimum received before the action", () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    expect(screen.getByText(/minimum received/i)).toBeVisible();
  });

  it("starts the whole intent from one application click", async () => {
    render(<BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />);
    await userEvent.click(screen.getByRole("button", { name: /add .* leverage/i }));

    // Progress replaces the button in the same surface: no second app
    // confirmation, and no modal.
    expect(screen.queryByRole("button", { name: /add .* leverage/i })).toBeNull();
    expect(screen.getByText("Open 1.25x position")).toBeVisible();
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("shows the approval step only when one is required", async () => {
    const { unmount } = render(
      <BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />,
    );
    await userEvent.click(screen.getByRole("button", { name: /add .* leverage/i }));
    expect(screen.getByText(/approve .* YES only/i)).toBeVisible();
    unmount();

    render(
      <BuilderView
        market={market}
        protocol={SCENARIOS.healthy.protocol}
        onBack={() => {}}
        outcomeAllowance={market.ownedYes}
      />,
    );
    await userEvent.click(screen.getByRole("button", { name: /add .* leverage/i }));
    expect(screen.queryByText(/approve .* YES only/i)).toBeNull();
  });

  it("keeps one solid violet object once progress replaces the button", async () => {
    const { container } = render(
      <BuilderView market={market} protocol={SCENARIOS.healthy.protocol} onBack={() => {}} />,
    );
    await userEvent.click(screen.getByRole("button", { name: /add .* leverage/i }));
    const { assertSingleAccentFill } = await import("../dev/accentGuard");
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });
});
