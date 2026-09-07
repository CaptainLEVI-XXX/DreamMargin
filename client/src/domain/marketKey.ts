import { encodeAbiParameters, keccak256 } from "viem";
import type { MarketKey } from "./models";

/**
 * Market-generation identity.
 *
 * Integration guide §16: never trust a pool address without checking market id,
 * nonce, token ids, and collateral. DreamDEX recycles pools onto new
 * generations, so a stale key would let the client enable leverage against a
 * different market than the one the user reviewed.
 *
 * This derivation mirrors the Solidity exactly. Its test pins it against the
 * live ETH YES generation key read from the Shannon deployment.
 */
export function generationKey(key: MarketKey): `0x${string}` {
  // Addresses reach the client in two forms: lowercase from the indexer and
  // checksummed from the deployment config. Solidity's `address` is
  // case-insensitive, so both must derive the same key. Normalize before
  // encoding rather than trusting the caller's casing.
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "uint64" },
        { type: "address" },
        { type: "uint256" },
        { type: "address" },
      ],
      [
        key.marketId.toLowerCase() as `0x${string}`,
        key.pool.toLowerCase() as `0x${string}`,
        key.marketNonce,
        key.outcomeToken.toLowerCase() as `0x${string}`,
        key.outcomeId,
        key.collateral.toLowerCase() as `0x${string}`,
      ],
    ),
  );
}

function sameAddress(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/**
 * Field-by-field comparison, as §6.1 requires before enabling leverage. A single
 * differing field means a different market generation.
 */
export function marketKeysEqual(a: MarketKey, b: MarketKey): boolean {
  return (
    sameAddress(a.marketId, b.marketId) &&
    sameAddress(a.pool, b.pool) &&
    a.marketNonce === b.marketNonce &&
    sameAddress(a.outcomeToken, b.outcomeToken) &&
    a.outcomeId === b.outcomeId &&
    sameAddress(a.collateral, b.collateral)
  );
}
