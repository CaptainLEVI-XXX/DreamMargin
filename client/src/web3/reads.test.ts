import { describe, expect, it } from "vitest";
import { DEPLOYMENT } from "../config/deployment";
import { logChunks, utilizationBps } from "./reads";

describe("utilizationBps", () => {
  it("reports zero for an empty vault without dividing by zero", () => {
    expect(utilizationBps(0n, 0n)).toBe(0n);
  });

  it("computes a clean ratio", () => {
    expect(utilizationBps(680n, 1_000n)).toBe(6_800n);
  });

  it("rounds up so a barely-used vault never reads as zero percent", () => {
    expect(utilizationBps(1n, 1_000_000n)).toBe(1n);
  });

  it("reports full utilization exactly", () => {
    expect(utilizationBps(1_000n, 1_000n)).toBe(10_000n);
  });

  it("matches the documented 80% cap boundary", () => {
    expect(utilizationBps(800n, 1_000n)).toBe(8_000n);
  });
});

describe("logChunks", () => {
  it("returns a single chunk when the range fits", () => {
    expect(logChunks(100n, 200n, 1_000n)).toEqual([{ from: 100n, to: 200n }]);
  });

  it("splits an oversized range without gaps or overlap", () => {
    const chunks = logChunks(0n, 250n, 100n);
    expect(chunks).toEqual([
      { from: 0n, to: 99n },
      { from: 100n, to: 199n },
      { from: 200n, to: 250n },
    ]);
  });

  it("covers a single block", () => {
    expect(logChunks(5n, 5n, 10n)).toEqual([{ from: 5n, to: 5n }]);
  });

  it("returns nothing when the range is empty", () => {
    expect(logChunks(10n, 9n, 10n)).toEqual([]);
  });

  it("rejects a non-positive chunk size", () => {
    expect(() => logChunks(0n, 10n, 0n)).toThrow(/positive/i);
  });

  it("chunks the real deployment scan range without overflowing a number", () => {
    const chunks = logChunks(
      DEPLOYMENT.deployedAtBlock,
      DEPLOYMENT.deployedAtBlock + 500_000n,
      50_000n,
    );
    expect(chunks).toHaveLength(11);
    expect(chunks[0].from).toBe(DEPLOYMENT.deployedAtBlock);
    // Contiguous: each chunk starts exactly where the previous ended.
    for (let i = 1; i < chunks.length; i += 1) {
      expect(chunks[i].from).toBe(chunks[i - 1].to + 1n);
    }
  });
});
