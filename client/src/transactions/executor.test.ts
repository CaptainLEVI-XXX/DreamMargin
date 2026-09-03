import { describe, expect, it, vi } from "vitest";
import type { Bounds } from "./bounds";
import { buildCallPlan, type PlanInput } from "./callPlan";
import { createIntent } from "./machine";
import { isUserRejection, runIntent, type ExecutorDeps } from "./executor";

const CONTROLLER = "0x50B054bD4A891C44A66c86e8c82A45AE0630869c" as const;
const NOW = 1_000_000n;
const reviewed: Bounds = {
  side: "buy",
  maxCollateralIn: 115_200_000n,
  minSharesOut: 177_000_000n,
  minSafetyBufferBps: 2_400n,
  deadline: NOW + 60n,
};

const withApproval: PlanInput = {
  action: { to: CONTROLLER, label: "Open 2x position" },
  erc6909: {
    token: CONTROLLER,
    spender: CONTROLLER,
    outcomeId: 1n,
    required: 200n,
    current: 0n,
    label: "Approve 200 YES only",
  },
};
const noApproval: PlanInput = { action: { to: CONTROLLER, label: "Settle position" } };

function deps(over: Partial<ExecutorDeps> = {}): ExecutorDeps {
  return {
    simulateApproval: vi.fn(async () => ({ request: "approval" })),
    simulateAction: vi.fn(async () => ({
      simulated: { request: "action" },
      fresh: { ...reviewed },
    })),
    send: vi.fn(async () => "0xhash"),
    sendBatch: vi.fn(async () => "0xbatch"),
    waitForReceipt: vi.fn(async () => ({ success: true })),
    verifyEvent: vi.fn(async () => true),
    reconcile: vi.fn(async () => {}),
    now: () => NOW,
    ...over,
  };
}

describe("runIntent sequential path", () => {
  const plan = buildCallPlan(withApproval);
  const caps = { atomicBatch: false };

  it("reaches success through approve, refresh, act, verify, reconcile", async () => {
    const d = deps();
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("success");
    expect(d.simulateApproval).toHaveBeenCalledTimes(1);
    expect(d.simulateAction).toHaveBeenCalledTimes(1);
    expect(d.reconcile).toHaveBeenCalledTimes(1);
  });

  it("simulates the action after the approval confirms, not before", async () => {
    const order: string[] = [];
    const d = deps({
      simulateApproval: vi.fn(async () => {
        order.push("simulate-approval");
        return { request: "a" };
      }),
      waitForReceipt: vi.fn(async () => {
        order.push("wait");
        return { success: true };
      }),
      simulateAction: vi.fn(async () => {
        order.push("simulate-action");
        return { simulated: { request: "b" }, fresh: { ...reviewed } };
      }),
    });
    await runIntent(createIntent(reviewed), plan, caps, d);
    expect(order.slice(0, 3)).toEqual(["simulate-approval", "wait", "simulate-action"]);
  });

  it("never signs twice concurrently", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const d = deps({
      send: vi.fn(async () => {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await Promise.resolve();
        inFlight -= 1;
        return "0xhash";
      }),
    });
    await runIntent(createIntent(reviewed), plan, caps, d);
    expect(maxInFlight).toBe(1);
  });

  it("skips approval when the plan has none", async () => {
    const d = deps();
    const result = await runIntent(createIntent(reviewed), buildCallPlan(noApproval), caps, d);
    expect(result.state.name).toBe("success");
    expect(d.simulateApproval).not.toHaveBeenCalled();
  });
});

describe("the gate stops a worsened quote before signing", () => {
  const plan = buildCallPlan(withApproval);
  const caps = { atomicBatch: false };

  it("stops at needs-review and never requests the action signature", async () => {
    const d = deps({
      simulateAction: vi.fn(async () => ({
        simulated: { request: "action" },
        fresh: { ...reviewed, maxCollateralIn: 999_000_000n },
      })),
    });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("needs-review");
    // The approval was signed; the action never was.
    expect(d.send).toHaveBeenCalledTimes(1);
    expect(d.reconcile).not.toHaveBeenCalled();
  });

  it("stops when the quote expired between review and execution", async () => {
    const d = deps({ now: () => reviewed.deadline! + 1n });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("needs-review");
    expect(d.send).toHaveBeenCalledTimes(1);
  });

  it("proceeds when the refreshed quote improved", async () => {
    const d = deps({
      simulateAction: vi.fn(async () => ({
        simulated: { request: "action" },
        fresh: { ...reviewed, maxCollateralIn: 1n, minSharesOut: 999_000_000n },
      })),
    });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("success");
    expect(d.send).toHaveBeenCalledTimes(2);
  });
});

describe("atomic batching", () => {
  it("sends one bundle and never a separate approval", async () => {
    const d = deps();
    const result = await runIntent(
      createIntent(reviewed),
      buildCallPlan(withApproval),
      { atomicBatch: true },
      d,
    );
    expect(result.state.name).toBe("success");
    expect(d.sendBatch).toHaveBeenCalledTimes(1);
    expect(d.send).not.toHaveBeenCalled();
    expect(d.simulateApproval).not.toHaveBeenCalled();
  });
});

describe("failure paths", () => {
  const plan = buildCallPlan(noApproval);
  const caps = { atomicBatch: false };

  it("treats a user rejection as recoverable, not an error", async () => {
    const d = deps({
      send: vi.fn(async () => {
        throw { code: 4001, message: "User rejected the request" };
      }),
    });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("idle");
  });

  it("reports a reverted transaction rather than claiming success", async () => {
    const d = deps({ waitForReceipt: vi.fn(async () => ({ success: false })) });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("error");
    if (result.state.name === "error") expect(result.state.message).toMatch(/reverted/i);
  });

  it("refuses success when the protocol event is missing", async () => {
    const d = deps({ verifyEvent: vi.fn(async () => false) });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("error");
    if (result.state.name === "error") expect(result.state.message).toMatch(/event/i);
    expect(d.reconcile).not.toHaveBeenCalled();
  });

  it("surfaces a simulation failure before any prompt", async () => {
    const d = deps({
      simulateAction: vi.fn(async () => {
        throw new Error("StaleOracle");
      }),
    });
    const result = await runIntent(createIntent(reviewed), plan, caps, d);
    expect(result.state.name).toBe("error");
    expect(d.send).not.toHaveBeenCalled();
  });

  it("never retries or resubmits on its own", async () => {
    const d = deps({
      send: vi.fn(async () => {
        throw new Error("network hiccup");
      }),
    });
    await runIntent(createIntent(reviewed), plan, caps, d);
    expect(d.send).toHaveBeenCalledTimes(1);
  });
});

describe("isUserRejection", () => {
  it("recognises EIP-1193 code 4001", () => {
    expect(isUserRejection({ code: 4001 })).toBe(true);
  });

  it("recognises rejection wording", () => {
    expect(isUserRejection({ message: "User denied transaction signature" })).toBe(true);
  });

  it("does not mistake other failures for a rejection", () => {
    expect(isUserRejection(new Error("StaleOracle"))).toBe(false);
    expect(isUserRejection(null)).toBe(false);
  });
});
