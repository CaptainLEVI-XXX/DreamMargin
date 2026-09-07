import { erc20Abi, type Address, type PublicClient } from "viem";
import { erc6909Abi } from "@somnia-chain/markets-sdk";
import { DEPLOYMENT } from "../config/deployment";

/**
 * Token balances and allowances.
 *
 * Collateral is a plain ERC-20; outcome shares are ERC-6909, addressed by
 * outcome id. §6.2: ERC-6909 has no wallet-wide enumeration, so balances are
 * read per known outcome id rather than discovered.
 */

export type Balances = {
  /** tUSDC, in native units at 6 decimals. */
  collateral: bigint;
  /** Allowance from the wallet to the controller, for repay and close. */
  collateralAllowance: bigint;
  /** Allowance from the wallet to the ERC-4626 vault, for deposits. */
  vaultAllowance: bigint;
  /** Vault shares held. */
  vaultShares: bigint;
  yes: bigint;
  no: bigint;
  /** Outcome allowance to the controller for the YES id, in shares. */
  yesAllowance: bigint;
  noAllowance: bigint;
};

export const EMPTY_BALANCES: Balances = {
  collateral: 0n,
  collateralAllowance: 0n,
  vaultAllowance: 0n,
  vaultShares: 0n,
  yes: 0n,
  no: 0n,
  yesAllowance: 0n,
  noAllowance: 0n,
};

/**
 * Read every balance the trader flow needs, batched through multicall3.
 *
 * Outcome and collateral allowances decide whether an approval is required, so
 * they are read alongside balances rather than separately at signing time.
 */
export async function readBalances(
  client: PublicClient,
  owner: Address,
  yesId: bigint,
  noId: bigint,
): Promise<Balances> {
  const collateralToken = DEPLOYMENT.collateral as Address;
  const outcomeToken = DEPLOYMENT.outcomeToken as Address;
  const controller = DEPLOYMENT.controller as Address;
  const vault = DEPLOYMENT.vault as Address;

  const [
    collateral,
    collateralAllowance,
    vaultAllowance,
    vaultShares,
    yes,
    no,
    yesAllowance,
    noAllowance,
  ] = await Promise.all([
    client.readContract({
      address: collateralToken,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [owner],
    }),
    client.readContract({
      address: collateralToken,
      abi: erc20Abi,
      functionName: "allowance",
      args: [owner, controller],
    }),
    client.readContract({
      address: collateralToken,
      abi: erc20Abi,
      functionName: "allowance",
      args: [owner, vault],
    }),
    client.readContract({
      address: vault,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [owner],
    }),
    client.readContract({
      address: outcomeToken,
      abi: erc6909Abi,
      functionName: "balanceOf",
      args: [owner, yesId],
    }) as Promise<bigint>,
    client.readContract({
      address: outcomeToken,
      abi: erc6909Abi,
      functionName: "balanceOf",
      args: [owner, noId],
    }) as Promise<bigint>,
    client.readContract({
      address: outcomeToken,
      abi: erc6909Abi,
      functionName: "allowance",
      args: [owner, controller, yesId],
    }) as Promise<bigint>,
    client.readContract({
      address: outcomeToken,
      abi: erc6909Abi,
      functionName: "allowance",
      args: [owner, controller, noId],
    }) as Promise<bigint>,
  ]);

  return {
    collateral,
    collateralAllowance,
    vaultAllowance,
    vaultShares,
    yes,
    no,
    yesAllowance,
    noAllowance,
  };
}
