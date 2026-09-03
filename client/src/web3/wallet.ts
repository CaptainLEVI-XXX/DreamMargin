import type { Address } from "viem";
import { DEPLOYMENT } from "../config/deployment";

/**
 * Minimal EIP-1193 wallet access.
 *
 * frontend-spec §17.1 governs every rule here: request connection only after the
 * user presses Connect; request a chain switch only when the user begins a
 * wallet-dependent action or presses Switch network; never prompt on page load,
 * connection completion, field edit, or a passive quote refresh.
 *
 * The connector UI is bespoke rather than a wallet-kit modal: the available kits
 * ship rounded, gradient-heavy surfaces that violate §18's hairline dark system.
 */

export type Eip1193 = {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
  on?: (event: string, handler: (...args: unknown[]) => void) => void;
  removeListener?: (event: string, handler: (...args: unknown[]) => void) => void;
};

export type WalletState =
  | { status: "unavailable" }
  | { status: "disconnected" }
  | { status: "connected"; account: Address; chainId: number; wrongChain: boolean };

export const SHANNON_CHAIN_ID = DEPLOYMENT.chainId;

/** The injected provider, or null when no wallet is present. */
export function getInjected(): Eip1193 | null {
  const injected = (globalThis as { ethereum?: Eip1193 }).ethereum;
  return injected ?? null;
}

function toChainId(raw: unknown): number {
  return typeof raw === "string" ? Number.parseInt(raw, 16) : Number(raw);
}

/**
 * Read wallet state without prompting. Uses `eth_accounts`, which returns
 * already-authorised accounts and never opens the wallet — §17.1 forbids a
 * prompt on page load.
 */
export async function readWallet(provider: Eip1193 | null): Promise<WalletState> {
  if (provider === null) return { status: "unavailable" };

  const accounts = (await provider.request({ method: "eth_accounts" })) as Address[];
  if (accounts.length === 0) return { status: "disconnected" };

  const chainId = toChainId(await provider.request({ method: "eth_chainId" }));
  return {
    status: "connected",
    account: accounts[0],
    chainId,
    wrongChain: chainId !== SHANNON_CHAIN_ID,
  };
}

/** Prompt for connection. Only ever called from an explicit user action. */
export async function connect(provider: Eip1193): Promise<WalletState> {
  const accounts = (await provider.request({ method: "eth_requestAccounts" })) as Address[];
  if (accounts.length === 0) return { status: "disconnected" };

  const chainId = toChainId(await provider.request({ method: "eth_chainId" }));
  return {
    status: "connected",
    account: accounts[0],
    chainId,
    wrongChain: chainId !== SHANNON_CHAIN_ID,
  };
}

/** Request a switch to Shannon. Only ever called from an explicit user action. */
export async function switchToShannon(provider: Eip1193): Promise<void> {
  await provider.request({
    method: "wallet_switchEthereumChain",
    params: [{ chainId: `0x${SHANNON_CHAIN_ID.toString(16)}` }],
  });
}

/** Shorten an address for the compact wallet button. §6.1 */
export function shortenAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}
