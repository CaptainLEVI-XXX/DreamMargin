import { describe, expect, it } from "vitest";
import { availabilityFor, PositionStatus, ProtocolMode } from "./protocol";

const base = {
  mode: ProtocolMode.Active,
  status: PositionStatus.Active,
  oracleStale: false,
  beforeOpeningCutoff: true,
  beforeReduceOnlyCutoff: true,
};

describe("availabilityFor", () => {
  it("permits everything when active and healthy", () => {
    const a = availabilityFor(base);
    expect(a.canOpen).toBe(true);
    expect(a.canBuy).toBe(true);
    expect(a.canRepay).toBe(true);
  });

  it("blocks opening but keeps repay available when paused", () => {
    const a = availabilityFor({ ...base, mode: ProtocolMode.Paused });
    expect(a.canOpen).toBe(false);
    expect(a.canRepay).toBe(true);
    expect(a.canAddCollateral).toBe(true);
    expect(a.canDeleverage).toBe(true);
    expect(a.canClose).toBe(true);
  });

  it("blocks opening but keeps risk reduction in reduce-only", () => {
    const a = availabilityFor({ ...base, mode: ProtocolMode.ReduceOnly });
    expect(a.canOpen).toBe(false);
    expect(a.canDeleverage).toBe(true);
    expect(a.canRepay).toBe(true);
  });

  it("blocks opening on a stale oracle but keeps repay and add collateral", () => {
    const a = availabilityFor({ ...base, oracleStale: true });
    expect(a.canOpen).toBe(false);
    expect(a.canRepay).toBe(true);
    expect(a.canAddCollateral).toBe(true);
  });

  it("blocks opening after the opening cutoff", () => {
    const a = availabilityFor({ ...base, beforeOpeningCutoff: false });
    expect(a.canOpen).toBe(false);
    expect(a.canRepay).toBe(true);
  });

  it("allows only settlement once resolved", () => {
    const a = availabilityFor({ ...base, status: PositionStatus.Resolved });
    expect(a.canSettle).toBe(true);
    expect(a.canOpen).toBe(false);
    expect(a.canDeleverage).toBe(false);
  });

  it("explains why opening is blocked", () => {
    expect(availabilityFor({ ...base, mode: ProtocolMode.Paused }).openBlockedReason).toMatch(
      /paused/i,
    );
    expect(availabilityFor({ ...base, oracleStale: true }).openBlockedReason).toMatch(/risk data/i);
    expect(availabilityFor({ ...base, mode: ProtocolMode.ReduceOnly }).openBlockedReason).toMatch(
      /reduction/i,
    );
  });

  it("gives no blocked reason when opening is allowed", () => {
    expect(availabilityFor(base).openBlockedReason).toBeUndefined();
  });
});
