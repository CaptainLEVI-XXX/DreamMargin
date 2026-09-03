import type { Address, PublicClient } from "viem";
import { DEPLOYMENT } from "../config/deployment";
import type { CapHeadroom } from "../domain/credit";
import type { MarketKey, VaultView } from "../domain/models";
import { generationKey, marketKeysEqual } from "../domain/marketKey";
import type { ProtocolModeValue } from "../domain/protocol";
import { controllerAbi } from "./abis/controllerAbi";
import { oracleAbi } from "./abis/oracleAbi";
import { vaultAbi } from "./abis/vaultAbi";

/**
 * Batched on-chain reads. Every function here is a single multicall round trip
 * where the chain allows it — the public client is created with
 * `batch: { multicall: true }`, so independent `readContract` calls in one tick
 * are aggregated through multicall3.
 *
 * Integration guide §6: the indexer never decides whether a risk-increasing
 * action is enabled. These reads do.
 */

const controller = { address: DEPLOYMENT.controller as Address, abi: controllerAbi } as const;
const vault = { address: DEPLOYMENT.vault as Address, abi: vaultAbi } as const;
const oracle = { address: DEPLOYMENT.oracle as Address, abi: oracleAbi } as const;

/**
 * Utilization in basis points, rounded up so a partly-used vault never reads as
 * 0%. Integer math only — never a float ratio.
 */
export function utilizationBps(performingDebt: bigint, totalAssets: bigint): bigint {
  if (totalAssets === 0n) return 0n;
  return (performingDebt * 10_000n + totalAssets - 1n) / totalAssets;
}

/**
 * Split a block range into `eth_getLogs`-sized windows. Public RPCs cap the
 * range, so the scan from the deployment block must be chunked.
 */
export function logChunks(
  fromBlock: bigint,
  toBlock: bigint,
  chunkSize: bigint,
): { from: bigint; to: bigint }[] {
  if (chunkSize <= 0n) throw new Error("chunk size must be positive");
  const chunks: { from: bigint; to: bigint }[] = [];
  let cursor = fromBlock;
  while (cursor <= toBlock) {
    const end = cursor + chunkSize - 1n > toBlock ? toBlock : cursor + chunkSize - 1n;
    chunks.push({ from: cursor, to: end });
    cursor = end + 1n;
  }
  return chunks;
}

export type GlobalRisk = {
  maxDebtGlobal: bigint;
  maxDailyRealizedLoss: bigint;
  maxVaultUtilizationBps: bigint;
  governanceDelay: bigint;
  lossWindow: bigint;
  lossCooldown: bigint;
};

export type ProtocolSnapshot = { mode: ProtocolModeValue; risk: GlobalRisk };

/** Protocol mode plus the global risk bounds every cap calculation needs. */
export async function readProtocol(client: PublicClient): Promise<ProtocolSnapshot> {
  const [mode, risk] = await Promise.all([
    client.readContract({ ...controller, functionName: "protocolMode" }),
    client.readContract({ ...controller, functionName: "globalRiskConfig" }),
  ]);

  const r = risk as unknown as {
    maxDebtGlobal: bigint;
    maxDailyRealizedLoss: bigint;
    maxVaultUtilizationBps: number | bigint;
    governanceDelay: number | bigint;
    lossWindow: number | bigint;
    lossCooldown: number | bigint;
  };

  return {
    mode: Number(mode) as ProtocolModeValue,
    risk: {
      maxDebtGlobal: r.maxDebtGlobal,
      maxDailyRealizedLoss: r.maxDailyRealizedLoss,
      maxVaultUtilizationBps: BigInt(r.maxVaultUtilizationBps),
      governanceDelay: BigInt(r.governanceDelay),
      lossWindow: BigInt(r.lossWindow),
      lossCooldown: BigInt(r.lossCooldown),
    },
  };
}

/**
 * Full ERC-4626 vault state. `maxWithdraw` and `maxRedeem` are authoritative
 * for what an LP can actually exit with — integration guide §2.2 forbids
 * estimating that from total assets.
 */
export async function readVault(
  client: PublicClient,
  owner: Address | null,
  collateralDecimals: number,
): Promise<VaultView> {
  const [
    totalAssets,
    availableLiquidity,
    performingDebt,
    protocolReserve,
    lockedReserve,
    realizedBadDebt,
  ] = await Promise.all([
    client.readContract({ ...vault, functionName: "totalAssets" }),
    client.readContract({ ...vault, functionName: "availableLiquidity" }),
    client.readContract({ ...vault, functionName: "performingDebt" }),
    client.readContract({ ...vault, functionName: "protocolReserve" }),
    client.readContract({ ...vault, functionName: "lockedReserve" }),
    client.readContract({ ...vault, functionName: "realizedBadDebt" }),
  ]);

  let walletShares = 0n;
  let walletAssets = 0n;
  let maxWithdraw = 0n;
  let maxRedeem = 0n;

  if (owner !== null) {
    [walletShares, maxWithdraw, maxRedeem] = await Promise.all([
      client.readContract({ ...vault, functionName: "balanceOf", args: [owner] }),
      client.readContract({ ...vault, functionName: "maxWithdraw", args: [owner] }),
      client.readContract({ ...vault, functionName: "maxRedeem", args: [owner] }),
    ]);
    walletAssets =
      walletShares === 0n
        ? 0n
        : await client.readContract({
            ...vault,
            functionName: "convertToAssets",
            args: [walletShares],
          });
  }

  return {
    totalAssets,
    availableLiquidity,
    performingDebt,
    utilizationBps: utilizationBps(performingDebt, totalAssets),
    protocolReserve,
    lockedReserve,
    realizedBadDebt,
    collateralDecimals,
    walletShares,
    walletAssets,
    maxWithdraw,
    maxRedeem,
  };
}

export type OracleSnapshot = {
  /** Conservative mark, or null when the oracle is stale or immature. */
  mark: bigint | null;
  /** Seconds since the newest retained observation. */
  updatedSecondsAgo: number;
  stale: boolean;
  /** Observations retained, and the ring's capacity. */
  cardinality: number;
  maxObservations: number;
  /** Why the mark is unavailable, when it is. */
  reason?: string;
};

/**
 * Oracle freshness and the conservative mark.
 *
 * `conservativeTwap` reverts rather than returning a sentinel when the oracle is
 * stale, so the revert is caught and decoded into a display state instead of
 * failing the whole read.
 */
export async function readOracle(
  client: PublicClient,
  key: `0x${string}`,
  nowSeconds: bigint,
): Promise<OracleSnapshot> {
  const state = (await client.readContract({
    ...oracle,
    functionName: "generationState",
    args: [key],
  })) as unknown as [
    { maxObservations: number; staleAfter: number },
    { cardinality: number; newestTimestamp: number },
  ];

  const [config, ring] = state;
  const updatedSecondsAgo = Number(nowSeconds - BigInt(ring.newestTimestamp));
  const stale = updatedSecondsAgo > Number(config.staleAfter);

  let mark: bigint | null = null;
  let reason: string | undefined;
  try {
    const twap = (await client.readContract({
      ...oracle,
      functionName: "conservativeTwap",
      args: [key],
    })) as unknown as readonly [bigint, bigint, bigint];
    mark = twap[0];
  } catch {
    reason = stale ? "Risk data is stale" : "Risk history is still building";
  }

  return {
    mark,
    updatedSecondsAgo,
    stale,
    cardinality: Number(ring.cardinality),
    maxObservations: Number(config.maxObservations),
    reason,
  };
}

export type GenerationSnapshot = {
  registered: boolean;
  enabled: boolean;
  frozen: boolean;
  /** True only when the on-chain key matches the candidate field by field. */
  keyMatches: boolean;
  headroomCaps: Pick<CapHeadroom, "position" | "outcome" | "market"> | null;
};

/**
 * Generation eligibility. §9.1 requires the key to recompute correctly and match
 * the registered configuration field by field before leverage is enabled — a
 * recycled pool must never pass this.
 */
export async function readGeneration(
  client: PublicClient,
  key: MarketKey,
): Promise<GenerationSnapshot> {
  const gk = generationKey(key);
  const generation = (await client.readContract({
    ...controller,
    functionName: "getGeneration",
    args: [gk],
  })) as unknown as {
    key: MarketKey;
    risk: { maxDebtPerPosition: bigint; maxDebtPerOutcome: bigint; maxDebtPerMarket: bigint };
    enabled: boolean;
    frozen: boolean;
  };

  const registered = generation.key.pool !== "0x0000000000000000000000000000000000000000";

  return {
    registered,
    enabled: generation.enabled,
    frozen: generation.frozen,
    keyMatches: registered && marketKeysEqual(key, generation.key),
    headroomCaps: registered
      ? {
          position: generation.risk.maxDebtPerPosition,
          outcome: generation.risk.maxDebtPerOutcome,
          market: generation.risk.maxDebtPerMarket,
        }
      : null,
  };
}

/**
 * Owner position ids from `PositionOpened` logs.
 *
 * The controller has no unbounded enumeration view, so logs from the deployment
 * block are the source of truth. Public RPCs cap `eth_getLogs` ranges, so the
 * scan is chunked and the caller can persist `nextFromBlock` as a cursor.
 */
export async function listPositionIds(
  client: PublicClient,
  owner: Address,
  fromBlock: bigint,
  toBlock: bigint,
  chunkSize = 50_000n,
): Promise<{ ids: bigint[]; nextFromBlock: bigint }> {
  const event = controllerAbi.find((e) => e.type === "event" && e.name === "PositionOpened");
  if (event === undefined) throw new Error("PositionOpened event missing from the ABI");

  const ids: bigint[] = [];

  for (const { from, to } of logChunks(fromBlock, toBlock, chunkSize)) {
    const logs = await client.getLogs({
      address: DEPLOYMENT.controller as Address,
      event: event as never,
      args: { owner } as never,
      fromBlock: from,
      toBlock: to,
    });
    for (const log of logs) {
      const id = (log as unknown as { args?: { positionId?: bigint } }).args?.positionId;
      if (id !== undefined) ids.push(id);
    }
  }

  return { ids, nextFromBlock: toBlock + 1n };
}
