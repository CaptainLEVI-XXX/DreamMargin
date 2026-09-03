import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { WalletButton } from "./WalletButton";

const ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678";
const noop = () => {};

describe("WalletButton", () => {
  it("says so when no wallet is installed", () => {
    render(
      <WalletButton state={{ status: "unavailable" }} onConnect={noop} onSwitchChain={noop} />,
    );
    expect(screen.getByText(/no wallet detected/i)).toBeVisible();
  });

  it("offers connection only as an explicit action", async () => {
    const onConnect = vi.fn();
    render(
      <WalletButton
        state={{ status: "disconnected" }}
        onConnect={onConnect}
        onSwitchChain={noop}
      />,
    );
    expect(onConnect).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole("button", { name: /connect wallet/i }));
    expect(onConnect).toHaveBeenCalledTimes(1);
  });

  it("offers a network switch on the wrong chain", async () => {
    const onSwitchChain = vi.fn();
    render(
      <WalletButton
        state={{ status: "connected", account: ACCOUNT, chainId: 1, wrongChain: true }}
        onConnect={noop}
        onSwitchChain={onSwitchChain}
      />,
    );
    await userEvent.click(screen.getByRole("button", { name: /switch network/i }));
    expect(onSwitchChain).toHaveBeenCalledTimes(1);
  });

  it("shows a shortened address and the network when connected", () => {
    render(
      <WalletButton
        state={{ status: "connected", account: ACCOUNT, chainId: 50312, wrongChain: false }}
        onConnect={noop}
        onSwitchChain={noop}
      />,
    );
    expect(screen.getByText("0x1234…5678")).toBeVisible();
    expect(screen.getByText("Shannon")).toBeVisible();
  });

  it("never fills violet, leaving that for the page's primary action", () => {
    const { container } = render(
      <WalletButton state={{ status: "disconnected" }} onConnect={noop} onSwitchChain={noop} />,
    );
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});
