import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
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

  it("offers real bounded supply and withdrawal actions without step-count copy", async () => {
    render(
      <EarnView
        vault={SCENARIOS.healthy.vault}
        account="0x1234567890abcdef1234567890abcdef12345678"
        balances={{ collateral: 500_000_000n, vaultAllowance: 0n }}
      />,
    );
    expect(screen.getByRole("button", { name: "Supply 100 tUSDC" })).toBeEnabled();
    expect(screen.queryByText(/wallet confirmations?/i)).toBeNull();

    await userEvent.click(screen.getByRole("button", { name: "Withdraw" }));
    expect(screen.getByRole("button", { name: "Withdraw tUSDC" })).toBeEnabled();
  });
});
