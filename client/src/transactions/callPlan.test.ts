import { describe, expect, it } from "vitest";
import { buildCallPlan, canBatch, readCapabilities, type PlanInput } from "./callPlan";

const CONTROLLER = "0x50B054bD4A891C44A66c86e8c82A45AE0630869c" as const;
const COLLATERAL = "0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E" as const;
const OUTCOME = "0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9" as const;

const openIntent: PlanInput = {
  action: { to: CONTROLLER, label: "Open 2x position" },
  erc6909: {
    token: OUTCOME,
    spender: CONTROLLER,
    outcomeId: 981762892987552592529876415592559547602498254264742346774773393025536n,
    required: 200_000_000n,
    current: 0n,
    label: "Approve 200 YES only",
  },
};

describe("buildCallPlan", () => {
  it("plans approval then action when allowance is missing", () => {
    const plan = buildCallPlan(openIntent);
    expect(plan.calls.map((c) => c.kind)).toEqual(["approve-erc6909", "action"]);
    expect(plan.sequentialConfirmations).toBe(2);
  });

  it("omits the approval entirely when allowance already suffices", () => {
    const plan = buildCallPlan({
      ...openIntent,
      erc6909: { ...openIntent.erc6909!, current: 200_000_000n },
    });
    expect(plan.calls.map((c) => c.kind)).toEqual(["action"]);
    expect(plan.sequentialConfirmations).toBe(1);
  });

  it("treats an allowance above the requirement as sufficient", () => {
    const plan = buildCallPlan({
      ...openIntent,
      erc6909: { ...openIntent.erc6909!, current: 999_000_000n },
    });
    expect(plan.calls).toHaveLength(1);
  });

  it("approves the exact amount, never unlimited", () => {
    const [approval] = buildCallPlan(openIntent).calls;
    expect(approval.amount).toBe(200_000_000n);
    expect(approval.amount).not.toBe(2n ** 256n - 1n);
  });

  it("carries the exact outcome id, so the approval is not a global operator grant", () => {
    const [approval] = buildCallPlan(openIntent).calls;
    expect(approval.outcomeId).toBe(openIntent.erc6909!.outcomeId);
  });

  it("plans an ERC-20 approval for a repayment", () => {
    const plan = buildCallPlan({
      action: { to: CONTROLLER, label: "Repay 50 tUSDC" },
      erc20: {
        token: COLLATERAL,
        spender: CONTROLLER,
        required: 50_000_000n,
        current: 0n,
        label: "Approve 50 tUSDC",
      },
    });
    expect(plan.calls.map((c) => c.kind)).toEqual(["approve-erc20", "action"]);
  });

  it("plans a single call for an action needing no approval", () => {
    const plan = buildCallPlan({ action: { to: CONTROLLER, label: "Settle position" } });
    expect(plan.calls).toHaveLength(1);
    expect(plan.sequentialConfirmations).toBe(1);
  });
});

describe("readCapabilities", () => {
  it("detects atomic support keyed by hex chain id", () => {
    expect(readCapabilities({ "0xc488": { atomic: { status: "supported" } } }, 50312)).toEqual({
      atomicBatch: true,
    });
  });

  it("detects atomic support keyed by decimal chain id", () => {
    expect(readCapabilities({ "50312": { atomic: { status: "ready" } } }, 50312)).toEqual({
      atomicBatch: true,
    });
  });

  it("accepts the older atomicBatch shape", () => {
    expect(readCapabilities({ "0xc488": { atomicBatch: { supported: true } } }, 50312)).toEqual({
      atomicBatch: true,
    });
  });

  it("reports no batching for a different chain", () => {
    expect(readCapabilities({ "0x1": { atomic: { status: "supported" } } }, 50312)).toEqual({
      atomicBatch: false,
    });
  });

  it("reports no batching when the wallet answers nothing", () => {
    expect(readCapabilities(null, 50312)).toEqual({ atomicBatch: false });
    expect(readCapabilities(undefined, 50312)).toEqual({ atomicBatch: false });
    expect(readCapabilities({}, 50312)).toEqual({ atomicBatch: false });
  });

  it("does not treat an unsupported status as support", () => {
    expect(readCapabilities({ "0xc488": { atomic: { status: "unsupported" } } }, 50312)).toEqual({
      atomicBatch: false,
    });
  });
});

describe("batching decisions", () => {
  const plan = buildCallPlan(openIntent);
  const single = buildCallPlan({ action: { to: CONTROLLER, label: "Settle position" } });

  it("batches a multi-call plan on a capable wallet", () => {
    expect(canBatch(plan, { atomicBatch: true })).toBe(true);
  });

  it("never batches on an incapable wallet", () => {
    expect(canBatch(plan, { atomicBatch: false })).toBe(false);
  });

  it("does not batch a single call", () => {
    expect(canBatch(single, { atomicBatch: true })).toBe(false);
  });
});
