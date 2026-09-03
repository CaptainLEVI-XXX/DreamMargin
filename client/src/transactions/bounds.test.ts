import { describe, expect, it } from "vitest";
import { checkBounds, type Bounds } from "./bounds";

const NOW = 1_000_000n;
const reviewed: Bounds = {
  side: "buy",
  maxCollateralIn: 115_200_000n,
  minSharesOut: 177_000_000n,
  limitPrice: 620_000n,
  minSafetyBufferBps: 2_400n,
  deadline: NOW + 60n,
};

describe("checkBounds", () => {
  it("passes an identical request", () => {
    expect(checkBounds(reviewed, { ...reviewed }, NOW)).toEqual({ ok: true });
  });

  it("passes a strictly better request", () => {
    const better: Bounds = {
      ...reviewed,
      maxCollateralIn: 110_000_000n,
      minSharesOut: 180_000_000n,
      limitPrice: 610_000n,
      minSafetyBufferBps: 2_600n,
    };
    expect(checkBounds(reviewed, better, NOW)).toEqual({ ok: true });
  });

  it("rejects paying more than the reviewed maximum", () => {
    const r = checkBounds(reviewed, { ...reviewed, maxCollateralIn: 115_200_001n }, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations[0].field).toBe("maxCollateralIn");
  });

  it("rejects receiving fewer shares than the reviewed minimum", () => {
    const r = checkBounds(reviewed, { ...reviewed, minSharesOut: 176_999_999n }, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations[0].field).toBe("minSharesOut");
  });

  it("rejects a worse buy price", () => {
    const r = checkBounds(reviewed, { ...reviewed, limitPrice: 620_001n }, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations[0].explanation).toMatch(/price moved/i);
  });

  it("accepts a better buy price", () => {
    expect(checkBounds(reviewed, { ...reviewed, limitPrice: 600_000n }, NOW).ok).toBe(true);
  });

  it("inverts the price direction for a sale", () => {
    const sell: Bounds = { side: "sell", limitPrice: 620_000n };
    expect(checkBounds(sell, { ...sell, limitPrice: 630_000n }, NOW).ok).toBe(true);
    expect(checkBounds(sell, { ...sell, limitPrice: 610_000n }, NOW).ok).toBe(false);
  });

  it("rejects any price change when the direction is unknown", () => {
    const noSide: Bounds = { limitPrice: 620_000n };
    expect(checkBounds(noSide, { limitPrice: 610_000n }, NOW).ok).toBe(false);
    expect(checkBounds(noSide, { limitPrice: 620_000n }, NOW).ok).toBe(true);
  });

  it("rejects a riskier resulting position", () => {
    const r = checkBounds(reviewed, { ...reviewed, minSafetyBufferBps: 2_399n }, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations[0].explanation).toMatch(/riskier/i);
  });

  it("rejects an expired quote even when every number improved", () => {
    const better: Bounds = {
      ...reviewed,
      maxCollateralIn: 1n,
      minSharesOut: 999_999_999n,
      limitPrice: 1n,
      minSafetyBufferBps: 9_000n,
    };
    const r = checkBounds(reviewed, better, reviewed.deadline!);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations[0].field).toBe("deadline");
  });

  it("accepts a quote one second before expiry", () => {
    expect(checkBounds(reviewed, { ...reviewed }, reviewed.deadline! - 1n).ok).toBe(true);
  });

  it("treats a dropped protection as a violation, not an improvement", () => {
    const r = checkBounds(reviewed, { side: "buy" }, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.violations.map((v) => v.field).sort()).toEqual(
        ["limitPrice", "maxCollateralIn", "minSafetyBufferBps", "minSharesOut"].sort(),
      );
      for (const v of r.violations) expect(v.explanation).toMatch(/missing/i);
    }
  });

  it("ignores a bound the user was never shown", () => {
    const r = checkBounds(
      { maxCollateralIn: 100n },
      { maxCollateralIn: 100n, minSharesOut: 1n },
      NOW,
    );
    expect(r.ok).toBe(true);
  });

  it("reports every violation, not only the first", () => {
    const worse: Bounds = {
      ...reviewed,
      maxCollateralIn: 200_000_000n,
      minSharesOut: 1n,
      minSafetyBufferBps: 1n,
    };
    const r = checkBounds(reviewed, worse, NOW);
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.violations).toHaveLength(3);
  });

  it("guards repayment and sale bounds in the right directions", () => {
    const close: Bounds = { maxRepayAssets: 100n, minCollateralOut: 50n };
    expect(checkBounds(close, { maxRepayAssets: 101n, minCollateralOut: 50n }, NOW).ok).toBe(false);
    expect(checkBounds(close, { maxRepayAssets: 99n, minCollateralOut: 50n }, NOW).ok).toBe(true);
    expect(checkBounds(close, { maxRepayAssets: 100n, minCollateralOut: 49n }, NOW).ok).toBe(false);
    expect(checkBounds(close, { maxRepayAssets: 100n, minCollateralOut: 51n }, NOW).ok).toBe(true);
  });
});

describe("no worsened quote can ever pass", () => {
  // Property check over the numeric bounds: a single worsening step in any
  // direction must be rejected, at every magnitude.
  const deltas = [1n, 2n, 7n, 1_000n, 10n ** 12n];

  it("rejects every magnitude of overpayment", () => {
    for (const d of deltas) {
      const r = checkBounds(reviewed, { ...reviewed, maxCollateralIn: 115_200_000n + d }, NOW);
      expect(r.ok, `delta ${d}`).toBe(false);
    }
  });

  it("rejects every magnitude of under-delivery", () => {
    for (const d of deltas) {
      const r = checkBounds(reviewed, { ...reviewed, minSharesOut: 177_000_000n - d }, NOW);
      expect(r.ok, `delta ${d}`).toBe(false);
    }
  });

  it("rejects every magnitude of health degradation", () => {
    for (const d of deltas) {
      const r = checkBounds(reviewed, { ...reviewed, minSafetyBufferBps: 2_400n - d }, NOW);
      expect(r.ok, `delta ${d}`).toBe(false);
    }
  });

  it("accepts every magnitude of improvement", () => {
    for (const d of deltas) {
      const r = checkBounds(
        reviewed,
        {
          ...reviewed,
          maxCollateralIn: 115_200_000n - d,
          minSharesOut: 177_000_000n + d,
          minSafetyBufferBps: 2_400n + d,
        },
        NOW,
      );
      expect(r.ok, `delta ${d}`).toBe(true);
    }
  });
});
