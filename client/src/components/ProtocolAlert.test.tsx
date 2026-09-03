import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ProtocolAlert } from "./ProtocolAlert";
import { SCENARIOS } from "../fixtures/scenarios";
import { ProtocolMode } from "../domain/protocol";

describe("ProtocolAlert", () => {
  it("shows the testnet notice when nothing else applies", () => {
    const s = SCENARIOS.healthy;
    render(<ProtocolAlert protocol={s.protocol} positions={s.positions} />);
    expect(screen.getByRole("status")).toHaveTextContent(/testnet/i);
  });

  it("shows exactly one alert at a time", () => {
    const s = SCENARIOS.paused;
    render(<ProtocolAlert protocol={s.protocol} positions={s.positions} />);
    expect(screen.getAllByRole("status")).toHaveLength(1);
  });

  it("prioritises wrong chain above everything", () => {
    const s = SCENARIOS.paused;
    render(
      <ProtocolAlert protocol={{ ...s.protocol, wrongChain: true }} positions={s.positions} />,
    );
    expect(screen.getByRole("status")).toHaveTextContent(/Somnia/i);
  });

  it("prioritises paused above an at-risk position", () => {
    const s = SCENARIOS.atRisk;
    render(
      <ProtocolAlert
        protocol={{ ...s.protocol, mode: ProtocolMode.Paused }}
        positions={s.positions}
      />,
    );
    expect(screen.getByRole("status")).toHaveTextContent(/paused/i);
  });

  it("warns about an at-risk position above a resolved one", () => {
    const s = SCENARIOS.atRisk;
    render(<ProtocolAlert protocol={s.protocol} positions={s.positions} />);
    expect(screen.getByRole("status")).toHaveTextContent(/at risk/i);
  });

  it("offers a corrective action", () => {
    const s = SCENARIOS.atRisk;
    render(<ProtocolAlert protocol={s.protocol} positions={s.positions} />);
    expect(screen.getByRole("button")).toBeVisible();
  });
});
