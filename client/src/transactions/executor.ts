import type { Bounds } from "./bounds";
import type { CallPlan, WalletCapabilities } from "./callPlan";
import { canBatch } from "./callPlan";
import { transition, type Intent, type IntentEvent } from "./machine";

/**
 * Drives the intent machine against a real wallet.
 *
 * The machine decides *what* may happen; this decides *when*, by performing the
 * chain work between transitions. Every dependency is injected, so the whole
 * sequence — including the bounds gate and the rejection path — is testable
 * without a chain or a wallet.
 *
 * Integration guide §17: every write is simulated against the current block
 * immediately before signing. §12: never run wallet requests concurrently, and
 * never resubmit or loosen anything without a new explicit user action.
 */

export type SimulatedRequest = { request: unknown };

export type ExecutorDeps = {
  /** Simulate the approval call. Throws to abort before any prompt. */
  simulateApproval: () => Promise<SimulatedRequest>;
  /**
   * Refresh state and simulate the action, returning the bounds the refreshed
   * request actually implies. The machine compares these with the reviewed set.
   */
  simulateAction: () => Promise<{ simulated: SimulatedRequest; fresh: Bounds }>;
  /** Send one signed call, resolving to its hash. */
  send: (simulated: SimulatedRequest) => Promise<string>;
  /** Send the whole plan as one atomic bundle, resolving to its identifier. */
  sendBatch: (plan: CallPlan) => Promise<string>;
  /** Wait for inclusion. Resolves false when the transaction reverted. */
  waitForReceipt: (hash: string) => Promise<{ success: boolean }>;
  /** Confirm the expected protocol event is present in the receipt. */
  verifyEvent: (hash: string) => Promise<boolean>;
  /** Re-read authoritative state after the receipt. */
  reconcile: () => Promise<void>;
  /** Current time in unix seconds. */
  now: () => bigint;
};

export type Rejected = { code?: number; message?: string };

/** Wallets report a user rejection as EIP-1193 code 4001. */
export function isUserRejection(error: unknown): boolean {
  const e = error as Rejected | undefined;
  if (e === undefined || e === null) return false;
  if (e.code === 4001) return true;
  return /user rejected|user denied/i.test(e.message ?? "");
}

/**
 * Run one intent to completion.
 *
 * `onState` is called after every transition so the initiating panel can render
 * progress inline. The returned intent is the terminal one.
 */
export async function runIntent(
  start: Intent,
  plan: CallPlan,
  capabilities: WalletCapabilities,
  deps: ExecutorDeps,
  onState: (intent: Intent) => void = () => {},
): Promise<Intent> {
  let intent = start;

  const step = (event: IntentEvent): Intent => {
    intent = transition(intent, event);
    onState(intent);
    return intent;
  };

  step({ type: "start" });
  step({ type: "plan-ready", plan, capabilities });

  try {
    if (canBatch(plan, capabilities)) {
      // One decoded bundle, one signature. The reviewed bounds were checked
      // when the plan was built and nothing intervenes, so there is no second
      // gate on this path.
      const hash = await deps.sendBatch(plan);
      step({ type: "action-submitted", hash });
      const receipt = await deps.waitForReceipt(hash);
      if (!receipt.success) return step({ type: "failed", message: "The transaction reverted" });
      step({ type: "action-confirmed" });
    } else {
      const needsApproval = plan.calls.some((c) => c.kind !== "action");

      if (needsApproval) {
        const approval = await deps.simulateApproval();
        const approvalHash = await deps.send(approval);
        step({ type: "approval-submitted", hash: approvalHash });

        const approvalReceipt = await deps.waitForReceipt(approvalHash);
        if (!approvalReceipt.success) {
          return step({ type: "failed", message: "The approval reverted" });
        }
        step({ type: "approval-confirmed" });

        // A confirmed approval authorises preparing the second request, never
        // altering the reviewed trade. The gate decides whether it may proceed.
        const { simulated, fresh } = await deps.simulateAction();
        const gated = step({ type: "refresh-complete", fresh, nowSeconds: deps.now() });
        if (gated.state.name === "needs-review") return gated;

        const hash = await deps.send(simulated);
        step({ type: "action-submitted", hash });
        const receipt = await deps.waitForReceipt(hash);
        if (!receipt.success) return step({ type: "failed", message: "The transaction reverted" });
        step({ type: "action-confirmed" });
      } else {
        // No approval, so nothing can have changed between review and signing
        // beyond the block itself; simulate immediately before the prompt.
        const { simulated } = await deps.simulateAction();
        const hash = await deps.send(simulated);
        step({ type: "action-submitted", hash });
        const receipt = await deps.waitForReceipt(hash);
        if (!receipt.success) return step({ type: "failed", message: "The transaction reverted" });
        step({ type: "action-confirmed" });
      }
    }

    // A receipt is not success. The protocol event must be present, and
    // authoritative state must be re-read, before anything is called done.
    const verified = await deps.verifyEvent(
      "hash" in intent.state ? (intent.state as { hash: string }).hash : "",
    );
    if (!verified) {
      return step({ type: "failed", message: "The expected protocol event was not emitted" });
    }
    step({ type: "event-verified" });

    await deps.reconcile();
    return step({ type: "reconciled" });
  } catch (error) {
    if (isUserRejection(error)) return step({ type: "signature-rejected" });
    return step({
      type: "failed",
      message: error instanceof Error ? error.message : "The transaction could not be completed",
    });
  }
}
