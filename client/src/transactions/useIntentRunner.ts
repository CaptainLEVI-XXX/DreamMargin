import { useCallback, useState } from "react";
import type { Address } from "viem";
import { createReadClient } from "../web3/client";
import { getInjected } from "../web3/wallet";
import type { Intent as ActionIntent } from "./actions";
import { runIntent } from "./executor";
import { createIntent, type Intent } from "./machine";
import { transition } from "./machine";
import type { WalletCapabilities } from "./callPlan";
import { createWallet, explainRevert, viemDeps } from "./viemExecutor";

/**
 * Runs any action intent against the wallet, exposing the machine state so the
 * initiating panel can render progress inline.
 *
 * One runner for every intent, so approval scope, simulation, the reviewed
 * bounds gate, event verification, and reconciliation behave identically
 * wherever an action is started from.
 */
export function useIntentRunner(
  account: Address | null,
  capabilities: WalletCapabilities,
  onSettled?: () => void,
) {
  const [intent, setIntent] = useState<Intent | null>(null);
  const [runningLabel, setRunningLabel] = useState<string | null>(null);

  const reset = useCallback(() => {
    setIntent(null);
    setRunningLabel(null);
  }, []);

  const run = useCallback(
    (action: ActionIntent) => {
      const provider = getInjected();
      if (provider === null || account === null) {
        setRunningLabel(action.label);
        setIntent(
          transition(
            transition(transition(createIntent(action.reviewed), { type: "start" }), {
              type: "plan-ready",
              plan: action.plan,
              capabilities,
            }),
            { type: "failed", message: "Connect a wallet to continue" },
          ),
        );
        return;
      }

      setRunningLabel(action.label);
      const publicClient = createReadClient();

      const deps = viemDeps({
        publicClient,
        walletClient: createWallet(provider, account),
        account,
        provider,
        approval:
          action.approval === undefined || action.plan.calls.every((c) => c.kind === "action")
            ? undefined
            : {
                address: action.approval.address,
                abi: action.approval.abi,
                functionName: action.approval.functionName,
                args: action.approval.args,
              },
        buildAction: async () => ({
          functionName: action.action.functionName,
          args: action.action.args,
          fresh: action.reviewed,
        }),
        actionAddress: action.action.address,
        actionAbi: action.action.abi,
        expectedEvent: action.expectedEvent,
        reconcile: async () => {
          onSettled?.();
        },
      });

      return runIntent(createIntent(action.reviewed), action.plan, capabilities, deps, setIntent)
        .then((result) => {
          if (result.state.name === "success") {
            // Show confirmation briefly, then restore the refreshed action
            // surface without requiring a redundant Continue click.
            window.setTimeout(() => setIntent(null), 1_200);
          }
          return result;
        })
        .catch((error: unknown) => {
          setIntent((current) =>
            current === null
              ? current
              : transition(current, { type: "failed", message: explainRevert(error) }),
          );
          return undefined;
        });
    },
    [account, capabilities, onSettled],
  );

  return { intent, runningLabel, run, reset };
}
