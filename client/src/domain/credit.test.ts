import { describe, expect, it } from "vitest";
import { availableCredit, type CapHeadroom, type CapKind } from "./credit";

const wide: CapHeadroom = {
  position: 100_000_000n,
  outcome: 300_000_000n,
  market: 500_000_000n,
  global: 1_000_000_000n,
  utilization: 800_000_000n,
  vaultCash: 900_000_000n,
};

describe("availableCredit", () => {
  it("returns the smallest headroom", () => {
    expect(availableCredit(wide).available).toBe(100_000_000n);
  });

  it("names the position cap when it binds", () => {
    expect(availableCredit(wide).binding).toBe("position");
  });

  it("names the market cap when it binds", () => {
    const r = availableCredit({ ...wide, market: 40_000_000n });
    expect(r.available).toBe(40_000_000n);
    expect(r.binding).toBe("market");
  });

  it("names vault cash when it binds", () => {
    const r = availableCredit({ ...wide, vaultCash: 0n });
    expect(r.available).toBe(0n);
    expect(r.binding).toBe("vaultCash");
  });

  it("names utilization when it binds", () => {
    const r = availableCredit({ ...wide, utilization: 5_000_000n });
    expect(r.binding).toBe("utilization");
  });

  it("never returns a negative amount", () => {
    const r = availableCredit({ ...wide, global: -50n });
    expect(r.available).toBe(0n);
    expect(r.binding).toBe("global");
  });

  it("supplies plain-language copy for every cap", () => {
    const kinds: CapKind[] = [
      "position",
      "outcome",
      "market",
      "global",
      "utilization",
      "vaultCash",
    ];
    for (const key of kinds) {
      const r = availableCredit({ ...wide, [key]: 1n });
      expect(r.binding).toBe(key);
      expect(r.explanation.length).toBeGreaterThan(0);
    }
  });
});
