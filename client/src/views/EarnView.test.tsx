import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { EarnView } from "./EarnView";
import { SCENARIOS } from "../fixtures/scenarios";

describe("EarnView", () => {
  it("states that LP principal is at risk", () => {
    render(<EarnView vault={SCENARIOS.healthy.vault} />);
    expect(screen.getByText(/principal is at risk/i)).toBeVisible();
  });

  it("shows utilization and available cash", () => {
    render(<EarnView vault={SCENARIOS.healthy.vault} />);
    expect(screen.getByText(/utilization/i)).toBeVisible();
    expect(screen.getByText(/available cash/i)).toBeVisible();
  });

  it("treats maxWithdraw as authoritative", () => {
    render(<EarnView vault={SCENARIOS.healthy.vault} />);
    expect(screen.getByText(/withdrawable now/i)).toBeVisible();
  });

  it("labels the rate an estimate, never Net APY", () => {
    render(<EarnView vault={SCENARIOS.healthy.vault} />);
    expect(screen.queryByText(/net apy/i)).toBeNull();
  });

  it("uses a specific action label", () => {
    const { container } = render(<EarnView vault={SCENARIOS.healthy.vault} />);
    expect(container.querySelector("[data-accent-fill]")).toHaveTextContent(/supply/i);
  });
});
