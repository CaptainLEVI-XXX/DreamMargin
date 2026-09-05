import { describe, expect, it, vi } from "vitest";
import {
  connect,
  disconnect,
  readWallet,
  shortenAddress,
  switchToShannon,
  SHANNON_CHAIN_ID,
  type Eip1193,
} from "./wallet";

const ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678";

function provider(overrides: Record<string, unknown>): Eip1193 {
  return {
    request: vi.fn(async ({ method }: { method: string }) => {
      if (method in overrides) return overrides[method];
      throw new Error(`unexpected method ${method}`);
    }),
  };
}

describe("readWallet", () => {
  it("reports unavailable with no injected provider", async () => {
    expect(await readWallet(null)).toEqual({ status: "unavailable" });
  });

  it("reports disconnected without prompting", async () => {
    const p = provider({ eth_accounts: [] });
    expect(await readWallet(p)).toEqual({ status: "disconnected" });
  });

  it("never calls eth_requestAccounts, which would open the wallet on load", async () => {
    const p = provider({ eth_accounts: [], eth_chainId: "0xc488" });
    await readWallet(p);
    const calls = (p.request as ReturnType<typeof vi.fn>).mock.calls.map(
      (c) => (c[0] as { method: string }).method,
    );
    expect(calls).not.toContain("eth_requestAccounts");
  });

  it("reports a connected account on Shannon", async () => {
    const p = provider({
      eth_accounts: [ACCOUNT],
      eth_chainId: `0x${SHANNON_CHAIN_ID.toString(16)}`,
    });
    expect(await readWallet(p)).toEqual({
      status: "connected",
      account: ACCOUNT,
      chainId: SHANNON_CHAIN_ID,
      wrongChain: false,
    });
  });

  it("flags the wrong chain rather than silently switching", async () => {
    const p = provider({ eth_accounts: [ACCOUNT], eth_chainId: "0x1" });
    const state = await readWallet(p);
    expect(state).toMatchObject({ status: "connected", chainId: 1, wrongChain: true });
  });
});

describe("connect", () => {
  it("prompts and returns the account", async () => {
    const p = provider({
      eth_requestAccounts: [ACCOUNT],
      eth_chainId: `0x${SHANNON_CHAIN_ID.toString(16)}`,
    });
    expect(await connect(p)).toMatchObject({ status: "connected", account: ACCOUNT });
  });

  it("reports disconnected when the user approves nothing", async () => {
    const p = provider({ eth_requestAccounts: [] });
    expect(await connect(p)).toEqual({ status: "disconnected" });
  });
});

describe("switchToShannon", () => {
  it("requests the Shannon chain id in hex", async () => {
    const p = provider({ wallet_switchEthereumChain: null });
    await switchToShannon(p);
    expect(p.request).toHaveBeenCalledWith({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0xc488" }],
    });
  });
});

describe("disconnect", () => {
  it("asks the provider to revoke account access", async () => {
    const p = provider({ wallet_revokePermissions: null });
    await disconnect(p);
    expect(p.request).toHaveBeenCalledWith({
      method: "wallet_revokePermissions",
      params: [{ eth_accounts: {} }],
    });
  });

  it("allows local disconnection when revocation is unsupported", async () => {
    await expect(disconnect(provider({}))).resolves.toBeUndefined();
  });
});

describe("shortenAddress", () => {
  it("keeps the leading and trailing characters", () => {
    expect(shortenAddress(ACCOUNT)).toBe("0x1234…5678");
  });
});
