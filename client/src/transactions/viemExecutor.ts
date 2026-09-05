import {
  createWalletClient,
  custom,
  decodeErrorResult,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hash,
  type PublicClient,
  type WalletClient,
} from "viem";
import { somniaShannon } from "@somnia-chain/markets-sdk/chains";
import { DEPLOYMENT } from "../config/deployment";
import { describeContractError } from "../domain/errors";
import { controllerAbi } from "../web3/abis/controllerAbi";
import { errorsAbi } from "../web3/abis/errorsAbi";
import { vaultAbi } from "../web3/abis/vaultAbi";
import type { Eip1193 } from "../web3/wallet";
import type { CallPlan } from "./callPlan";
import type { ExecutorDeps, SimulatedRequest } from "./executor";

/** Errors surfaced by the Solady tokens used inside DreamDEX integrations. */
const integrationErrorsAbi = parseAbi(["error InsufficientBalance()"]);

/**
 * The viem-backed half of the executor: everything that actually touches a
 * wallet or the chain.
 *
 * Kept apart from `executor.ts` so the orchestration rules — the bounds gate,
 * the ordering, the rejection path — stay testable without a chain, while this
 * module holds only mechanics.
 */

export function createWallet(provider: Eip1193, account: Address): WalletClient {
  return createWalletClient({
    account,
    chain: somniaShannon,
    transport: custom(provider as never),
  });
}

/**
 * Decode a contract revert into user-facing copy.
 *
 * The custom errors live in the errors library rather than the interfaces, so
 * that ABI is what makes a revert legible. frontend-spec §15 forbids replacing a
 * named contract error with generic wording.
 */
export function explainRevert(error: unknown): string {
  const data = findRevertData(error);
  if (data !== null) {
    try {
      const decoded = decodeErrorResult({ abi: [...errorsAbi, ...integrationErrorsAbi], data }) as {
        errorName?: string;
      };
      if (decoded.errorName !== undefined) return describeContractError(decoded.errorName).message;
    } catch {
      // Fall through to the name-matching path below.
    }
  }

  const message = error instanceof Error ? error.message : String(error);
  if (/function .+ not found on abi/i.test(message)) {
    return "The app could not prepare this transaction. Refresh the page to load the current contract interface.";
  }
  const named = /([A-Z][A-Za-z0-9]+)\(/.exec(message);
  if (named !== null) {
    const copy = describeContractError(named[1]);
    if (copy.known) return copy.message;
  }
  return message;
}

function findRevertData(error: unknown): `0x${string}` | null {
  let cursor = error as { data?: unknown; cause?: unknown } | undefined;
  for (let depth = 0; depth < 6 && cursor != null; depth += 1) {
    const data = cursor.data;
    if (typeof data === "string" && data.startsWith("0x") && data.length >= 10) {
      return data as `0x${string}`;
    }
    cursor = cursor.cause as { data?: unknown; cause?: unknown } | undefined;
  }
  return null;
}

export type ActionRequest = {
  functionName: string;
  args: readonly unknown[];
};

export type ViemDepsInput = {
  publicClient: PublicClient;
  walletClient: WalletClient;
  account: Address;
  provider: Eip1193;
  /** Approval call, when the plan needs one. */
  approval?: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args: readonly unknown[];
  };
  /** The action, rebuilt fresh at simulation time. */
  buildAction: () => Promise<ActionRequest & { fresh: import("./bounds").Bounds }>;
  /** Contract the action targets. Defaults to the controller. */
  actionAddress?: Address;
  /** ABI for the action. Defaults to the controller ABI. */
  actionAbi?: readonly unknown[];
  /**
   * Protocol event that must appear in the receipt. When absent — as for the
   * testnet faucet, which emits only a transfer — a successful receipt is
   * accepted on its own.
   */
  expectedEvent?: string;
  /** Re-read authoritative state after the receipt. */
  reconcile: () => Promise<void>;
};

/** Build executor dependencies backed by a real wallet and chain. */
export function viemDeps(input: ViemDepsInput): ExecutorDeps {
  const { publicClient, walletClient, account, provider } = input;

  return {
    async simulateApproval(): Promise<SimulatedRequest> {
      if (input.approval === undefined) throw new Error("no approval planned");
      try {
        const { request } = await publicClient.simulateContract({
          account,
          address: input.approval.address,
          abi: input.approval.abi as never,
          functionName: input.approval.functionName as never,
          args: input.approval.args as never,
        });
        return { request };
      } catch (error) {
        throw new Error(explainRevert(error), { cause: error });
      }
    },

    async simulateAction() {
      const action = await input.buildAction();
      // §17: simulate against the current block immediately before signing.
      try {
        const { request } = await publicClient.simulateContract({
          account,
          address: input.actionAddress ?? (DEPLOYMENT.controller as Address),
          abi: (input.actionAbi ?? controllerAbi) as never,
          functionName: action.functionName as never,
          args: action.args as never,
        });
        return { simulated: { request }, fresh: action.fresh };
      } catch (error) {
        throw new Error(explainRevert(error), { cause: error });
      }
    },

    async send(simulated) {
      return walletClient.writeContract((simulated as { request: never }).request);
    },

    async sendBatch(plan: CallPlan) {
      // EIP-5792. Only reached when the wallet reported atomic support.
      const result = (await provider.request({
        method: "wallet_sendCalls",
        params: [
          {
            version: "2.0.0",
            chainId: `0x${DEPLOYMENT.chainId.toString(16)}`,
            from: account,
            atomicRequired: true,
            calls: plan.calls.map((c) => ({ to: c.to })),
          },
        ],
      })) as { id?: string } | string;
      return typeof result === "string" ? result : (result.id ?? "");
    },

    async waitForReceipt(hash: string) {
      const receipt = await publicClient.waitForTransactionReceipt({ hash: hash as Hash });
      return { success: receipt.status === "success" };
    },

    async verifyEvent(hash: string) {
      // No named event means the receipt itself is the whole result.
      if (input.expectedEvent === undefined) return true;
      const receipt = await publicClient.getTransactionReceipt({ hash: hash as Hash });
      const events = parseEventLogs({
        abi: [...controllerAbi, ...vaultAbi] as never,
        logs: receipt.logs,
        eventName: input.expectedEvent as never,
      });
      return events.length > 0;
    },

    reconcile: input.reconcile,
    now: () => BigInt(Math.floor(Date.now() / 1000)),
  };
}
