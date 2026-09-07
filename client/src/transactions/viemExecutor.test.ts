import { encodeErrorResult } from "viem";
import { describe, expect, it } from "vitest";
import { errorsAbi } from "../web3/abis/errorsAbi";
import { explainRevert } from "./viemExecutor";

describe("explainRevert", () => {
  it("maps a named contract error to its recovery copy", () => {
    expect(explainRevert(new Error("execution reverted: StaleOracle(0x12, 6826, 600)"))).toMatch(
      /stale/i,
    );
  });

  it("decodes custom-error data returned without a readable message", () => {
    const data = encodeErrorResult({
      abi: errorsAbi,
      errorName: "StaleOracle",
      args: [`0x${"12".repeat(32)}`, 6826n, 600n],
    });
    expect(explainRevert({ data })).toMatch(/stale/i);
  });

  it("decodes an integrated Solady token balance error", () => {
    expect(explainRevert({ data: "0xf4d678b8" })).toMatch(/wallet balance/i);
  });

  it("turns an ABI mismatch into a recovery action instead of viem internals", () => {
    expect(explainRevert(new Error('Function "openPosition" not found on ABI.'))).toBe(
      "The app could not prepare this transaction. Refresh the page to load the current contract interface.",
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
