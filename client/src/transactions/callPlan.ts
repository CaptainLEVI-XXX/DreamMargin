import type { Address } from "viem";

/**
 * Call planning and wallet capability detection.
 *
 * frontend-spec §4.8: one application action starts the whole economic intent.
 * Where the wallet can execute an atomic batch, approval and action are one
 * decoded bundle; otherwise the orchestrator sequences them and reports each
 * transaction's progress inline. §17.2: fewer prompts come from reusing existing
 * allowances and batching. The Shannon demo may deliberately establish a
 * reusable allowance while still comparing the live allowance with the exact
 * amount required by each action.
 */

export type CallKind = "approve-erc20" | "approve-erc6909" | "action";

export type PlannedCall = {
  kind: CallKind;
  /** Short label shown in transaction progress. */
  label: string;
  to: Address;
  /** Amount authorised by an approval. */
  amount?: bigint;
  /** Exact outcome id authorised, for an ERC-6909 approval. */
  outcomeId?: bigint;
};

export type CallPlan = {
  calls: PlannedCall[];
  /** Wallet confirmations the user should expect if batching is unavailable. */
  sequentialConfirmations: number;
};

export type Erc20AllowanceNeed = {
  token: Address;
  spender: Address;
  required: bigint;
  current: bigint;
  label: string;
  /** Amount encoded in the approval; defaults to the immediate requirement. */
  approvalAmount?: bigint;
};

export type Erc6909AllowanceNeed = {
  token: Address;
  spender: Address;
  outcomeId: bigint;
  required: bigint;
  current: bigint;
  label: string;
  /** Amount encoded for this exact outcome id. */
  approvalAmount?: bigint;
};

export type PlanInput = {
  action: { to: Address; label: string };
  erc20?: Erc20AllowanceNeed;
  erc6909?: Erc6909AllowanceNeed;
};

/**
 * Build the calls one intent needs.
 *
 * An allowance that is already sufficient produces no approval call at all:
 * §4.8 requires an existing allowance to remove the step rather than showing it
 * as a completed task the user must acknowledge.
 */
export function buildCallPlan(input: PlanInput): CallPlan {
  const calls: PlannedCall[] = [];

  if (input.erc20 !== undefined && input.erc20.current < input.erc20.required) {
    calls.push({
      kind: "approve-erc20",
      label: input.erc20.label,
      to: input.erc20.token,
      amount: input.erc20.approvalAmount ?? input.erc20.required,
    });
  }

  if (input.erc6909 !== undefined && input.erc6909.current < input.erc6909.required) {
    calls.push({
      kind: "approve-erc6909",
      label: input.erc6909.label,
      to: input.erc6909.token,
      amount: input.erc6909.approvalAmount ?? input.erc6909.required,
      outcomeId: input.erc6909.outcomeId,
    });
  }

  calls.push({ kind: "action", label: input.action.label, to: input.action.to });

  return { calls, sequentialConfirmations: calls.length };
}

/** EIP-5792 capability report for one account and chain. */
export type WalletCapabilities = {
  atomicBatch: boolean;
};

type CapabilityResponse = Record<
  string,
  { atomic?: { status?: string }; atomicBatch?: { supported?: boolean } }
>;

/**
 * Feature-detect atomic batching. §4.8 requires detection rather than a promise:
 * the interface must not claim a single popup for every wallet.
 *
 * Both the current `atomic.status` shape and the earlier `atomicBatch.supported`
 * shape are accepted, since wallets are mid-migration between them.
 */
export function readCapabilities(
  response: CapabilityResponse | null | undefined,
  chainId: number,
): WalletCapabilities {
  if (response === null || response === undefined) return { atomicBatch: false };

  const key = Object.keys(response).find((k) => {
    const parsed = k.startsWith("0x") ? Number.parseInt(k, 16) : Number(k);
    return parsed === chainId;
  });
  if (key === undefined) return { atomicBatch: false };

  const entry = response[key];
  const status = entry.atomic?.status;
  if (status === "supported" || status === "ready") return { atomicBatch: true };
  return { atomicBatch: entry.atomicBatch?.supported === true };
}

/**
 * Whether this plan may be sent as one atomic bundle. A single call is never
 * worth batching, and batching is used only when the wallet promises atomicity.
 */
export function canBatch(plan: CallPlan, capabilities: WalletCapabilities): boolean {
  return capabilities.atomicBatch && plan.calls.length > 1;
}
