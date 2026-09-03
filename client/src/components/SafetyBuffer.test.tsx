import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { SafetyBuffer } from "./SafetyBuffer";

describe("SafetyBuffer", () => {
  it("shows the buffer as a percentage", () => {
    render(<SafetyBuffer bufferBps={2400n} liquidationLabel="48¢" updatedSecondsAgo={18} />);
    expect(screen.getByText("24%")).toBeVisible();
  });

  it("shows the liquidation boundary", () => {
    render(<SafetyBuffer bufferBps={2400n} liquidationLabel="48¢" updatedSecondsAgo={18} />);
    expect(screen.getByText(/48¢/)).toBeVisible();
  });

  it("pairs the state with a text label, never colour alone", () => {
    render(<SafetyBuffer bufferBps={600n} liquidationLabel="27¢" updatedSecondsAgo={4} />);
    expect(screen.getByText("At risk")).toBeVisible();
  });

  it("exposes the buffer to assistive technology", () => {
    render(<SafetyBuffer bufferBps={2400n} liquidationLabel="48¢" updatedSecondsAgo={18} />);
    const meter = screen.getByRole("meter");
    expect(meter).toHaveAttribute("aria-valuenow", "24");
    expect(meter).toHaveAccessibleName(/safety buffer/i);
  });

  it("reports observation age", () => {
    render(<SafetyBuffer bufferBps={2400n} liquidationLabel="48¢" updatedSecondsAgo={18} />);
    expect(screen.getByText("Updated 18s ago")).toBeVisible();
  });

  it("marks stale data explicitly", () => {
    render(
      <SafetyBuffer bufferBps={2400n} liquidationLabel="48¢" updatedSecondsAgo={6858} stale />,
    );
    expect(screen.getByText(/stale/i)).toBeVisible();
  });

  it("clamps a negative buffer to an empty bar", () => {
    render(<SafetyBuffer bufferBps={-500n} liquidationLabel="12¢" updatedSecondsAgo={2} />);
    expect(screen.getByRole("meter")).toHaveAttribute("aria-valuenow", "0");
    expect(screen.getByText("Liquidatable")).toBeVisible();
  });
});
