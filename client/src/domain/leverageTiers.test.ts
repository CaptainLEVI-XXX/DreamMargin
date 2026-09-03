import { describe, expect, it } from "vitest";
import { defaultTier, formatMultiple, tiersFor } from "./leverageTiers";

describe("tiersFor", () => {
  it("produces quarter steps up to the deployed 2x maximum", () => {
    expect(tiersFor(20_000n)).toEqual([10_000n, 12_500n, 15_000n, 17_500n, 20_000n]);
  });

  it("never exceeds the contract maximum", () => {
    expect(tiersFor(15_000n)).toEqual([10_000n, 12_500n, 15_000n]);
  });

  it("omits unsupported tiers entirely rather than disabling them", () => {
    expect(tiersFor(15_000n)).not.toContain(20_000n);
  });

  it("returns spot only when leverage is unavailable", () => {
    expect(tiersFor(10_000n)).toEqual([10_000n]);
  });

  it("extends when governance raises the cap", () => {
    expect(tiersFor(30_000n)).toContain(30_000n);
    expect(tiersFor(30_000n)).toContain(25_000n);
  });
});

describe("formatMultiple", () => {
  it("uses lowercase suffix form", () => {
    expect(formatMultiple(20_000n)).toBe("2x");
    expect(formatMultiple(10_000n)).toBe("1x");
  });

  it("keeps a fractional multiple readable", () => {
    expect(formatMultiple(12_500n)).toBe("1.25x");
  });

  it("never uses a capital X or a multiplication sign", () => {
    for (const bps of [10_000n, 12_500n, 20_000n, 30_000n]) {
      expect(formatMultiple(bps)).not.toMatch(/X|×/);
    }
  });
});

describe("defaultTier", () => {
  it("never preselects the maximum", () => {
    const tiers = tiersFor(20_000n);
    expect(defaultTier(tiers)).not.toBe(tiers[tiers.length - 1]);
  });

  it("chooses the lowest useful tier above spot", () => {
    expect(defaultTier(tiersFor(20_000n))).toBe(12_500n);
  });

  it("falls back to spot when no leverage exists", () => {
    expect(defaultTier(tiersFor(10_000n))).toBe(10_000n);
  });
});
