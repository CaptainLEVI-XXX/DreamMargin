import { describe, expect, it } from "vitest";
import { SCENARIOS, type ScenarioName } from "./scenarios";
import { ProtocolMode } from "../domain/protocol";

const NAMES: ScenarioName[] = [
  "healthy",
  "atRisk",
  "resolved",
  "staleOracle",
  "reduceOnly",
  "paused",
];

describe("SCENARIOS", () => {
  it("covers all six protocol states the design requires", () => {
    expect(Object.keys(SCENARIOS).sort()).toEqual([...NAMES].sort());
  });

  it("uses bigint for every money value", () => {
    for (const name of NAMES) {
      const s = SCENARIOS[name];
      expect(typeof s.vault.totalAssets).toBe("bigint");
      for (const m of s.markets) expect(typeof m.yesPrice).toBe("bigint");
      for (const p of s.positions) expect(typeof p.debtAssets).toBe("bigint");
    }
  });

  it("keeps market price, risk mark, and exit value distinct per §4.5", () => {
    const m = SCENARIOS.healthy.markets[0];
    expect(m.yesPrice).not.toBe(m.riskMark);
    expect(m.riskMark).not.toBe(m.estimatedExitValue);
  });

  it("caps leverage at the deployed 2.0x", () => {
    for (const m of SCENARIOS.healthy.markets) expect(m.maxLeverageBps).toBe(20_000n);
  });

  it("marks the stale-oracle scenario past the 600s freshness window", () => {
    for (const m of SCENARIOS.staleOracle.markets) {
      expect(m.oracleStale).toBe(true);
      expect(m.oracleUpdatedSecondsAgo).toBeGreaterThan(600);
    }
  });

  it("puts the at-risk position below the watch threshold", () => {
    expect(SCENARIOS.atRisk.positions[0].bufferBps).toBeLessThan(1_000n);
  });

  it("keeps the healthy position genuinely comfortable, not one step from a warning", () => {
    expect(SCENARIOS.healthy.positions[0].bufferBps).toBeGreaterThanOrEqual(2_500n);
  });

  it("sets the protocol mode for degraded scenarios", () => {
    expect(SCENARIOS.reduceOnly.protocol.mode).toBe(ProtocolMode.ReduceOnly);
    expect(SCENARIOS.paused.protocol.mode).toBe(ProtocolMode.Paused);
  });

  it("carries the full market key, never a pool address alone", () => {
    const k = SCENARIOS.healthy.markets[0].key;
    expect(k.marketId).toMatch(/^0x[0-9a-f]{64}$/i);
    expect(typeof k.marketNonce).toBe("bigint");
    expect(typeof k.outcomeId).toBe("bigint");
  });
});
