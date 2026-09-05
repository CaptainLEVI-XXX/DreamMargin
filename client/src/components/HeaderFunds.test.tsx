import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { HeaderFunds } from "./HeaderFunds";

describe("HeaderFunds", () => {
  it("keeps the test balance and faucet together outside the wallet menu", async () => {
    const onFaucet = vi.fn();
    render(<HeaderFunds collateral={12_345_000n} onFaucet={onFaucet} />);

    expect(screen.getByLabelText("tUSDC balance")).toHaveTextContent("12.34tUSDC");
    await userEvent.click(screen.getByRole("button", { name: "Faucet" }));
    expect(onFaucet).toHaveBeenCalledTimes(1);
  });
});
