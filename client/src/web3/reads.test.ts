import { describe, expect, it, vi } from "vitest";
import { readPositionIds, utilizationBps } from "./reads";

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

describe("position enumeration", () => {
  it("drains bounded controller pages without an event-log scan", async () => {
    const readContract = vi
      .fn()
      .mockResolvedValueOnce([[1n, 2n], 3n])
      .mockResolvedValueOnce([[3n], 3n]);

    await expect(
      readPositionIds({ readContract } as never, "0x1234567890abcdef1234567890abcdef12345678", 2),
    ).resolves.toEqual([1n, 2n, 3n]);
    expect(readContract).toHaveBeenCalledTimes(2);
    expect(readContract.mock.calls[1][0].args.slice(1)).toEqual([2n, 2n]);
  });
});
