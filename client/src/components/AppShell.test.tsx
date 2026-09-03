import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AppShell } from "./AppShell";

describe("AppShell", () => {
  it("renders the lowercase wordmark", () => {
    render(
      <AppShell route="markets" onNavigate={() => {}}>
        <p>content</p>
      </AppShell>,
    );
    expect(screen.getByText("dreammargin")).toBeVisible();
  });

  it("offers the three primary destinations", () => {
    render(
      <AppShell route="markets" onNavigate={() => {}}>
        <p>content</p>
      </AppShell>,
    );
    // Two navs exist in the DOM — desktop and mobile — but CSS `display: none`
    // removes whichever is hidden from the accessibility tree at any breakpoint.
    const desktop = screen.getByRole("navigation", { name: "Primary" });
    const mobile = screen.getByRole("navigation", { name: "Primary mobile" });
    for (const nav of [desktop, mobile]) {
      for (const label of ["Markets", "Positions", "Earn"]) {
        expect(within(nav).getByRole("link", { name: label })).toBeInTheDocument();
      }
    }
  });

  it("marks the active destination", () => {
    render(
      <AppShell route="positions" onNavigate={() => {}}>
        <p>content</p>
      </AppShell>,
    );
    const [active] = screen.getAllByRole("link", { name: "Positions" });
    expect(active).toHaveAttribute("aria-current", "page");
  });

  it("navigates when a destination is chosen", async () => {
    const onNavigate = vi.fn();
    render(
      <AppShell route="markets" onNavigate={onNavigate}>
        <p>content</p>
      </AppShell>,
    );
    await userEvent.click(screen.getAllByRole("link", { name: "Earn" })[0]);
    expect(onNavigate).toHaveBeenCalledWith("earn");
  });

  it("renders its children", () => {
    render(
      <AppShell route="markets" onNavigate={() => {}}>
        <p>page body</p>
      </AppShell>,
    );
    expect(screen.getByText("page body")).toBeVisible();
  });

  it("does not put a high-risk open action in navigation", () => {
    render(
      <AppShell route="markets" onNavigate={() => {}}>
        <p>content</p>
      </AppShell>,
    );
    const desktop = screen.getByRole("navigation", { name: "Primary" });
    const mobile = screen.getByRole("navigation", { name: "Primary mobile" });
    expect(desktop.textContent).not.toMatch(/open|leverage|buy/i);
    expect(mobile.textContent).not.toMatch(/open|leverage|buy/i);
  });
});
