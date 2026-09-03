import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { LeverageTiers } from "./LeverageTiers";

describe("LeverageTiers", () => {
  it("renders one chip per supported tier", () => {
    render(<LeverageTiers maxLeverageBps={20_000n} selected={12_500n} onSelect={() => {}} />);
    expect(screen.getByRole("radio", { name: "1x" })).toBeVisible();
    expect(screen.getByRole("radio", { name: "2x" })).toBeVisible();
    expect(screen.getAllByRole("radio")).toHaveLength(5);
  });

  it("omits tiers above the contract maximum", () => {
    render(<LeverageTiers maxLeverageBps={15_000n} selected={12_500n} onSelect={() => {}} />);
    expect(screen.queryByRole("radio", { name: "2x" })).toBeNull();
    expect(screen.queryByRole("radio", { name: "5x" })).toBeNull();
  });

  it("marks the selected tier", () => {
    render(<LeverageTiers maxLeverageBps={20_000n} selected={15_000n} onSelect={() => {}} />);
    expect(screen.getByRole("radio", { name: "1.5x" })).toBeChecked();
  });

  it("reports a selection", async () => {
    const onSelect = vi.fn();
    render(<LeverageTiers maxLeverageBps={20_000n} selected={12_500n} onSelect={onSelect} />);
    await userEvent.click(screen.getByRole("radio", { name: "2x" }));
    expect(onSelect).toHaveBeenCalledWith(20_000n);
  });

  it("groups the chips for assistive technology", () => {
    render(<LeverageTiers maxLeverageBps={20_000n} selected={12_500n} onSelect={() => {}} />);
    expect(screen.getByRole("radiogroup", { name: /leverage/i })).toBeVisible();
  });

  it("never fills a chip with solid violet, leaving that for the action", () => {
    const { container } = render(
      <LeverageTiers maxLeverageBps={20_000n} selected={20_000n} onSelect={() => {}} />,
    );
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});
