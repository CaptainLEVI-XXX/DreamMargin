import { describe, expect, it } from "vitest";
import { riskStateFromBufferBps } from "./risk";

describe("riskStateFromBufferBps", () => {
  it("classifies a wide buffer as comfortable", () => {
    expect(riskStateFromBufferBps(4000n).level).toBe("comfortable");
  });

  it("treats 25% as the comfortable boundary", () => {
    expect(riskStateFromBufferBps(2500n).level).toBe("comfortable");
  });

  it("classifies just below 25% as watch", () => {
    expect(riskStateFromBufferBps(2499n).level).toBe("watch");
  });

  it("treats 10% as the watch boundary", () => {
    expect(riskStateFromBufferBps(1000n).level).toBe("watch");
  });

  it("classifies just below 10% as at-risk", () => {
    expect(riskStateFromBufferBps(999n).level).toBe("at-risk");
  });

  it("classifies a zero buffer as liquidatable", () => {
    expect(riskStateFromBufferBps(0n).level).toBe("liquidatable");
  });

  it("classifies a negative buffer as liquidatable", () => {
    expect(riskStateFromBufferBps(-500n).level).toBe("liquidatable");
  });

  it("always supplies a non-empty label and icon", () => {
    for (const bps of [4000n, 2000n, 500n, 0n, -100n]) {
      const state = riskStateFromBufferBps(bps);
      expect(state.label.length).toBeGreaterThan(0);
      expect(state.icon.length).toBeGreaterThan(0);
    }
  });

  it("uses the spec's wording", () => {
    expect(riskStateFromBufferBps(4000n).label).toBe("Safe");
    expect(riskStateFromBufferBps(2000n).label).toBe("Watch");
    expect(riskStateFromBufferBps(500n).label).toBe("At risk");
    expect(riskStateFromBufferBps(0n).label).toBe("Liquidatable");
  });
});
