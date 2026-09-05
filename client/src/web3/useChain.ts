import { useCallback, useEffect, useState } from "react";
import { DEPLOYMENT } from "../config/deployment";
import type { VaultView } from "../domain/models";
import { createReadClient } from "./client";
import { checkBindings } from "./bindings";
import { readProtocol, readVault, type ProtocolSnapshot } from "./reads";
import { controllerAbi } from "./abis/controllerAbi";
import { oracleAbi } from "./abis/oracleAbi";
import { vaultAbi } from "./abis/vaultAbi";
import { connect, getInjected, readWallet, switchToShannon, type WalletState } from "./wallet";

/**
 * Live chain state for the shell.
 *
 * Reads only. Every write still belongs to the transaction engine, which is not
 * built yet, so nothing here can produce a signature. §17.1: the wallet is read
 * with `eth_accounts` on mount, which never prompts; `connect` and
 * `switchToShannon` run only from an explicit user action.
 */

export type ChainStatus =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ready"; protocol: ProtocolSnapshot; vault: VaultView };

const COLLATERAL_DECIMALS = 6;

export function useWallet() {
  const [state, setState] = useState<WalletState>({ status: "disconnected" });

  useEffect(() => {
    let cancelled = false;
    void readWallet(getInjected()).then((next) => {
      if (!cancelled) setState(next);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const doConnect = useCallback(async () => {
    const provider = getInjected();
    if (provider === null) return;
    setState(await connect(provider));
  }, []);

  const doSwitch = useCallback(async () => {
    const provider = getInjected();
    if (provider === null) return;
    await switchToShannon(provider);
    setState(await readWallet(provider));
  }, []);

  return { wallet: state, connect: doConnect, switchChain: doSwitch };
}

export function useChain(account: string | null, refreshKey = 0): ChainStatus {
  const [status, setStatus] = useState<ChainStatus>({ kind: "loading" });

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      try {
        const client = createReadClient();
        const c = { address: DEPLOYMENT.controller as `0x${string}`, abi: controllerAbi } as const;
        const v = { address: DEPLOYMENT.vault as `0x${string}`, abi: vaultAbi } as const;
        const o = { address: DEPLOYMENT.oracle as `0x${string}`, abi: oracleAbi } as const;

        // Integration guide §3: refuse to run against a deployment whose wiring
        // disagrees with configuration, before reading anything else.
        const [cv, co, cm, vc, va, oc] = await Promise.all([
          client.readContract({ ...c, functionName: "vault" }),
          client.readContract({ ...c, functionName: "oracle" }),
          client.readContract({ ...c, functionName: "module" }),
          client.readContract({ ...v, functionName: "controller" }),
          client.readContract({ ...v, functionName: "asset" }),
          client.readContract({ ...o, functionName: "configurator" }),
        ]);

        const bindings = checkBindings({
          controllerVault: cv,
          controllerOracle: co,
          controllerModule: cm,
          vaultController: vc,
          vaultAsset: va,
          oracleConfigurator: oc,
        });

        if (!bindings.ok) {
          if (!cancelled) {
            setStatus({
              kind: "error",
              message: `Deployment bindings do not match configuration: ${bindings.mismatches.join(", ")}`,
            });
          }
          return;
        }

        const [protocol, vault] = await Promise.all([
          readProtocol(client),
          readVault(client, account as `0x${string}` | null, COLLATERAL_DECIMALS),
        ]);

        if (!cancelled) setStatus({ kind: "ready", protocol, vault });
      } catch (error) {
        if (!cancelled) {
          setStatus({
            kind: "error",
            message: error instanceof Error ? error.message : "Could not reach Somnia Shannon",
          });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [account, refreshKey]);

  return status;
}
