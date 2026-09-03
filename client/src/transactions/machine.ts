import { checkBounds, type Bounds, type BoundsViolation } from "./bounds";
import { canBatch, type CallPlan, type WalletCapabilities } from "./callPlan";

/**
 * The intent state machine — integration guide §12.
 *
 * One economic intent, one application action, and a sequence of wallet
 * confirmations the orchestrator drives without asking the user to click again.
 * The exception is the reviewed-bounds gate: after an approval confirms, the
 * refreshed request is re-simulated and compared against what the user saw. If
 * anything worsened, the machine stops at `needs-review` rather than signing.
 *
 * Success is never submission. It requires a receipt, the expected protocol
 * event, and reconciled reads.
 */

export type IntentState =
  | { name: "idle" }
  | { name: "preparing" }
  | { name: "awaiting-batch-signature" }
  | { name: "awaiting-approval-signature" }
  | { name: "approval-pending"; hash: string }
  | { name: "refreshing" }
  | { name: "awaiting-action-signature" }
  | { name: "action-pending"; hash: string }
  | { name: "confirming"; hash: string }
  | { name: "reconciling"; hash: string }
  | { name: "success"; hash: string }
  | { name: "needs-review"; violations: BoundsViolation[] }
  | { name: "error"; message: string; recoverable: true };

export type IntentEvent =
  | { type: "start" }
  | { type: "plan-ready"; plan: CallPlan; capabilities: WalletCapabilities }
  | { type: "signature-rejected" }
  | { type: "approval-submitted"; hash: string }
  | { type: "approval-confirmed" }
  | { type: "refresh-complete"; fresh: Bounds; nowSeconds: bigint }
  | { type: "action-submitted"; hash: string }
  | { type: "action-confirmed" }
  | { type: "event-verified" }
  | { type: "reconciled" }
  | { type: "failed"; message: string };

export type IntentContext = {
  /** Exactly what the user was shown before pressing the action. */
  reviewed: Bounds;
  plan: CallPlan | null;
  capabilities: WalletCapabilities;
};

export type Intent = { state: IntentState; context: IntentContext };

export function createIntent(reviewed: Bounds): Intent {
  return {
    state: { name: "idle" },
    context: { reviewed, plan: null, capabilities: { atomicBatch: false } },
  };
}

/** Whether the machine has finished and inputs may be cleared. */
export function isTerminal(state: IntentState): boolean {
  return state.name === "success";
}

/** Whether the user's inputs must be preserved. §4.10 and §17.1 */
export function preservesInputs(state: IntentState): boolean {
  return state.name === "needs-review" || state.name === "error" || state.name === "idle";
}

/**
 * Advance the machine. Pure: no chain calls, no timers, no React — so every
 * transition is testable in isolation.
 */
export function transition(intent: Intent, event: IntentEvent): Intent {
  const { state, context } = intent;

  if (event.type === "failed") {
    return { state: { name: "error", message: event.message, recoverable: true }, context };
  }

  // A rejected signature is not an error. It returns to a prepared state with
  // inputs intact, ready to resume. §9.2 and §17.1
  if (event.type === "signature-rejected") {
    return { state: { name: "idle" }, context };
  }

  switch (state.name) {
    case "idle":
    case "needs-review":
    case "error":
      if (event.type === "start") return { state: { name: "preparing" }, context };
      return intent;

    case "preparing":
      if (event.type === "plan-ready") {
        const next = { ...context, plan: event.plan, capabilities: event.capabilities };
        const batched = canBatch(event.plan, event.capabilities);
        if (batched) return { state: { name: "awaiting-batch-signature" }, context: next };
        const needsApproval = event.plan.calls.some((c) => c.kind !== "action");
        return {
          state: {
            name: needsApproval ? "awaiting-approval-signature" : "awaiting-action-signature",
          },
          context: next,
        };
      }
      return intent;

    case "awaiting-approval-signature":
      if (event.type === "approval-submitted") {
        return { state: { name: "approval-pending", hash: event.hash }, context };
      }
      return intent;

    case "approval-pending":
      // A confirmed approval authorises preparing the second request, never
      // altering the reviewed trade. §12
      if (event.type === "approval-confirmed") return { state: { name: "refreshing" }, context };
      return intent;

    case "refreshing":
      if (event.type === "refresh-complete") {
        const check = checkBounds(context.reviewed, event.fresh, event.nowSeconds);
        if (!check.ok) {
          return { state: { name: "needs-review", violations: check.violations }, context };
        }
        return { state: { name: "awaiting-action-signature" }, context };
      }
      return intent;

    case "awaiting-batch-signature":
    case "awaiting-action-signature":
      if (event.type === "action-submitted") {
        return { state: { name: "action-pending", hash: event.hash }, context };
      }
      return intent;

    case "action-pending":
      if (event.type === "action-confirmed") {
        return { state: { name: "confirming", hash: state.hash }, context };
      }
      return intent;

    case "confirming":
      // A receipt alone is not success: the protocol event must be present. §12
      if (event.type === "event-verified") {
        return { state: { name: "reconciling", hash: state.hash }, context };
      }
      return intent;

    case "reconciling":
      // Success requires reconciled authoritative reads, not submission.
      if (event.type === "reconciled") {
        return { state: { name: "success", hash: state.hash }, context };
      }
      return intent;

    default:
      return intent;
  }
}

/** Progress steps for the initiating surface. §9.2 */
export type StepStatus = "ready" | "active" | "complete" | "skipped";

export function progressSteps(intent: Intent): { label: string; status: StepStatus }[] {
  const { state, context } = intent;
  if (context.plan === null) return [];

  const batched = canBatch(context.plan, context.capabilities);
  const order = [
    "preparing",
    "awaiting-approval-signature",
    "approval-pending",
    "refreshing",
    "awaiting-batch-signature",
    "awaiting-action-signature",
    "action-pending",
    "confirming",
    "reconciling",
    "success",
  ];
  const index = order.indexOf(state.name);

  return context.plan.calls.map((call) => {
    if (call.kind === "action") {
      if (state.name === "success") return { label: call.label, status: "complete" as const };
      if (index >= order.indexOf("awaiting-action-signature") || batched) {
        return { label: call.label, status: "active" as const };
      }
      return { label: call.label, status: "ready" as const };
    }

    if (batched) {
      // Grouped under one signature, but still displayed as its own decoded call.
      return { label: call.label, status: state.name === "success" ? "complete" : "active" };
    }
    if (index > order.indexOf("approval-pending")) {
      return { label: call.label, status: "complete" as const };
    }
    if (index >= order.indexOf("awaiting-approval-signature")) {
      return { label: call.label, status: "active" as const };
    }
    return { label: call.label, status: "ready" as const };
  });
}
