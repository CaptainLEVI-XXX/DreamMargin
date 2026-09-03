import { somniaShannon } from "@somnia-chain/markets-sdk/chains";
import { createPublicClient, http, type PublicClient } from "viem";
import { DEPLOYMENT } from "../config/deployment";

/**
 * One public client for every read. Multicall batching is enabled, using the
 * multicall3 the SDK's Shannon chain definition already points at, so a full
 * position read is one round trip rather than nine.
 */
export function createReadClient(rpcUrl?: string): PublicClient {
  return createPublicClient({
    chain: somniaShannon,
    transport: http(rpcUrl),
    batch: { multicall: true },
  });
}

export { DEPLOYMENT, somniaShannon };
