import { describe, expect, it } from "vitest";
import { explainRevert } from "./viemExecutor";

describe("explainRevert", () => {
  it("maps a named contract error to its recovery copy", () => {
    expect(explainRevert(new Error("execution reverted: StaleOracle(0x12, 6826, 600)"))).toMatch(
      /stale/i,
    );
  });

  it("maps an insufficient-depth revert", () => {
    expect(explainRevert(new Error("InsufficientBookDepth(100, 50)"))).toMatch(
      /larger than supported liquidity/i,
    );
  });

  it("maps a debt cap revert", () => {
    expect(explainRevert(new Error("DebtCapExceeded(1, 2)"))).toMatch(/credit limit/i);
  });

  it("never degrades a known error to generic wording", () => {
    for (const name of ["StaleOracle", "PoolRecycled", "InsufficientHealth", "IncompleteClose"]) {
      const copy = explainRevert(new Error(`${name}(1)`));
      expect(copy).not.toMatch(/something went wrong/i);
      expect(copy.length).toBeGreaterThan(0);
    }
  });

  it("keeps the original message for an unrecognised failure", () => {
    expect(explainRevert(new Error("nonce too low"))).toBe("nonce too low");
  });

  it("handles a non-Error value without throwing", () => {
    expect(() => explainRevert("boom")).not.toThrow();
    expect(explainRevert("boom")).toBe("boom");
  });
});
