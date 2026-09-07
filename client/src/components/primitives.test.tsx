import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { assertSingleAccentFill } from "../dev/accentGuard";
import { Button } from "./Button";
import { Card } from "./Card";
import { Value } from "./Value";

describe("Button", () => {
  it("marks the primary variant as the accent fill", () => {
    render(<Button variant="primary">Add 2x leverage</Button>);
    expect(screen.getByRole("button")).toHaveAttribute("data-accent-fill");
  });

  it("does not mark a secondary variant", () => {
    render(<Button variant="secondary">Add collateral</Button>);
    expect(screen.getByRole("button")).not.toHaveAttribute("data-accent-fill");
  });

  it("does not mark a tertiary variant", () => {
    render(<Button variant="tertiary">Details</Button>);
    expect(screen.getByRole("button")).not.toHaveAttribute("data-accent-fill");
  });

  it("explains itself when disabled", () => {
    render(
      <Button variant="primary" disabled disabledReason="Quote expired">
        Add 2x leverage
      </Button>,
    );
    expect(screen.getByRole("button")).toBeDisabled();
    expect(screen.getByRole("button")).toHaveAccessibleDescription("Quote expired");
  });

  it("keeps a single accent fill across one primary and two secondaries", () => {
    const { container } = render(
      <>
        <Button variant="primary">Repay</Button>
        <Button variant="secondary">Add collateral</Button>
        <Button variant="secondary">Deleverage</Button>
      </>,
    );
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });

  it("fails the guard when a view has two primaries", () => {
    const { container } = render(
      <>
        <Button variant="primary">Buy</Button>
        <Button variant="primary">Open</Button>
      </>,
    );
    expect(() => assertSingleAccentFill(container)).toThrow(/one solid violet/i);
  });
});

describe("Value", () => {
  it("renders with tabular figures", () => {
    render(<Value>62¢</Value>);
    expect(screen.getByText("62¢")).toHaveClass("dm-value");
  });
});

describe("Card", () => {
  it("renders its title and children", () => {
    render(
      <Card title="Open isolated position">
        <p>body</p>
      </Card>,
    );
    expect(screen.getByRole("heading", { name: "Open isolated position" })).toBeVisible();
    expect(screen.getByText("body")).toBeVisible();
  });

  it("renders without a title", () => {
    render(<Card>bare</Card>);
    expect(screen.getByText("bare")).toBeVisible();
    expect(screen.queryByRole("heading")).toBeNull();
  });
});
