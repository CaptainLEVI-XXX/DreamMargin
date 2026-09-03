import { describe, expect, it } from "vitest";
import type { Bounds } from "./bounds";
import { buildCallPlan, type PlanInput } from "./callPlan";
import {
  createIntent,
  isTerminal,
  preservesInputs,
  progressSteps,
  transition,
  type Intent,
  type IntentEvent,
} from "./machine";

const CONTROLLER = "0x50B054bD4A891C44A66c86e8c82A45AE0630869c" as const;
const OUTCOME = "0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9" as const;
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
    token: OUTCOME,
    spender: CONTROLLER,
    outcomeId: 1n,
    required: 200_000_000n,
    current: 0n,
    label: "Approve 200 YES only",
  },
};
const noApproval: PlanInput = { action: { to: CONTROLLER, label: "Settle position" } };

function run(intent: Intent, events: IntentEvent[]): Intent {
  return events.reduce(transition, intent);
}

describe("sequential fallback", () => {
  const plan = buildCallPlan(withApproval);
  const capabilities = { atomicBatch: false };

  it("routes through approval when allowance is missing", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
    ]);
    expect(i.state.name).toBe("awaiting-approval-signature");
  });

  it("skips approval entirely when none is needed", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan: buildCallPlan(noApproval), capabilities },
    ]);
    expect(i.state.name).toBe("awaiting-action-signature");
  });

  it("refreshes after approval rather than signing straight away", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
    ]);
    expect(i.state.name).toBe("refreshing");
  });

  it("continues to the action signature with no second app click when bounds hold", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
      { type: "refresh-complete", fresh: { ...reviewed }, nowSeconds: NOW },
    ]);
    expect(i.state.name).toBe("awaiting-action-signature");
  });

  it("reaches success only after event verification and reconciliation", () => {
    const events: IntentEvent[] = [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
      { type: "refresh-complete", fresh: { ...reviewed }, nowSeconds: NOW },
      { type: "action-submitted", hash: "0xbbb" },
      { type: "action-confirmed" },
    ];
    const confirming = run(createIntent(reviewed), events);
    expect(confirming.state.name).toBe("confirming");

    const reconciling = transition(confirming, { type: "event-verified" });
    expect(reconciling.state.name).toBe("reconciling");

    const done = transition(reconciling, { type: "reconciled" });
    expect(done.state.name).toBe("success");
    expect(isTerminal(done.state)).toBe(true);
  });

  it("does not treat a submitted transaction as success", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan: buildCallPlan(noApproval), capabilities },
      { type: "action-submitted", hash: "0xbbb" },
    ]);
    expect(i.state.name).toBe("action-pending");
    expect(isTerminal(i.state)).toBe(false);
  });

  it("does not treat a confirmed receipt as success either", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan: buildCallPlan(noApproval), capabilities },
      { type: "action-submitted", hash: "0xbbb" },
      { type: "action-confirmed" },
    ]);
    expect(i.state.name).toBe("confirming");
    expect(isTerminal(i.state)).toBe(false);
  });
});

describe("the reviewed-bounds gate", () => {
  const plan = buildCallPlan(withApproval);
  const capabilities = { atomicBatch: false };
  const upToRefresh: IntentEvent[] = [
    { type: "start" },
    { type: "plan-ready", plan, capabilities },
    { type: "approval-submitted", hash: "0xaaa" },
    { type: "approval-confirmed" },
  ];

  it("stops for review when the refreshed request costs more", () => {
    const i = run(createIntent(reviewed), [
      ...upToRefresh,
      {
        type: "refresh-complete",
        fresh: { ...reviewed, maxCollateralIn: 999_000_000n },
        nowSeconds: NOW,
      },
    ]);
    expect(i.state.name).toBe("needs-review");
    if (i.state.name === "needs-review") {
      expect(i.state.violations[0].field).toBe("maxCollateralIn");
    }
  });

  it("stops for review when health degraded", () => {
    const i = run(createIntent(reviewed), [
      ...upToRefresh,
      { type: "refresh-complete", fresh: { ...reviewed, minSafetyBufferBps: 1n }, nowSeconds: NOW },
    ]);
    expect(i.state.name).toBe("needs-review");
  });

  it("stops for review when the quote expired, even if cheaper", () => {
    const i = run(createIntent(reviewed), [
      ...upToRefresh,
      {
        type: "refresh-complete",
        fresh: { ...reviewed, maxCollateralIn: 1n },
        nowSeconds: reviewed.deadline!,
      },
    ]);
    expect(i.state.name).toBe("needs-review");
  });

  it("preserves inputs when it stops for review", () => {
    const i = run(createIntent(reviewed), [
      ...upToRefresh,
      { type: "refresh-complete", fresh: { ...reviewed, minSharesOut: 1n }, nowSeconds: NOW },
    ]);
    expect(preservesInputs(i.state)).toBe(true);
  });

  it("can restart from needs-review without losing the reviewed bounds", () => {
    const stopped = run(createIntent(reviewed), [
      ...upToRefresh,
      { type: "refresh-complete", fresh: { ...reviewed, minSharesOut: 1n }, nowSeconds: NOW },
    ]);
    const restarted = transition(stopped, { type: "start" });
    expect(restarted.state.name).toBe("preparing");
    expect(restarted.context.reviewed).toEqual(reviewed);
  });
});

describe("atomic batching", () => {
  const plan = buildCallPlan(withApproval);

  it("goes straight to one signature on a capable wallet", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: true } },
    ]);
    expect(i.state.name).toBe("awaiting-batch-signature");
  });

  it("still displays both decoded calls when batched", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: true } },
    ]);
    expect(progressSteps(i)).toHaveLength(2);
  });
});

describe("rejection and failure", () => {
  const plan = buildCallPlan(withApproval);
  const capabilities = { atomicBatch: false };

  it("returns a rejected signature to a prepared state, not an error", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "signature-rejected" },
    ]);
    expect(i.state.name).toBe("idle");
    expect(preservesInputs(i.state)).toBe(true);
  });

  it("keeps a failure recoverable and preserves inputs", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "failed", message: "Risk data is stale" },
    ]);
    expect(i.state.name).toBe("error");
    if (i.state.name === "error") expect(i.state.recoverable).toBe(true);
    expect(preservesInputs(i.state)).toBe(true);
  });

  it("ignores events that do not apply to the current state", () => {
    const i = run(createIntent(reviewed), [{ type: "approval-confirmed" }]);
    expect(i.state.name).toBe("idle");
  });
});

describe("progress steps", () => {
  const plan = buildCallPlan(withApproval);
  const capabilities = { atomicBatch: false };

  it("shows no steps before a plan exists", () => {
    expect(progressSteps(createIntent(reviewed))).toEqual([]);
  });

  it("marks the approval complete once past it", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan, capabilities },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
      { type: "refresh-complete", fresh: { ...reviewed }, nowSeconds: NOW },
    ]);
    const steps = progressSteps(i);
    expect(steps[0].status).toBe("complete");
    expect(steps[1].status).toBe("active");
  });

  it("omits an approval step entirely when allowance sufficed", () => {
    const i = run(createIntent(reviewed), [
      { type: "start" },
      { type: "plan-ready", plan: buildCallPlan(noApproval), capabilities },
    ]);
    const steps = progressSteps(i);
    expect(steps).toHaveLength(1);
    expect(steps[0].label).toBe("Settle position");
  });
});
