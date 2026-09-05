import { parseAbi, type Address, type PublicClient } from "viem";
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
  maintenanceLtvBps: bigint;
  headroomCaps: Pick<CapHeadroom, "position" | "outcome" | "market"> | null;
};

export type BinaryBook = {
  yesBids: { price: bigint; quantity: bigint }[];
  yesAsks: { price: bigint; quantity: bigint }[];
  noBids: { price: bigint; quantity: bigint }[];
  noAsks: { price: bigint; quantity: bigint }[];
};

const binaryPoolReadAbi = parseAbi([
  "function getBookLevels(bool isBid, uint64 numLevels) view returns ((uint256 price, uint256 quantity)[] levels)",
]);

/** Read a bounded four-sided book directly from the DreamDEX pool. */
export async function readBinaryBook(
  client: PublicClient,
  pool: Address,
  oneCollateral: bigint,
  depth = 8,
): Promise<BinaryBook> {
  const [yesBids, yesAsks] = await Promise.all([
    client.readContract({
      address: pool,
      abi: binaryPoolReadAbi,
      functionName: "getBookLevels",
      args: [true, BigInt(depth)],
    }),
    client.readContract({
      address: pool,
      abi: binaryPoolReadAbi,
      functionName: "getBookLevels",
      args: [false, BigInt(depth)],
    }),
  ]);

  const bids = [...yesBids];
  const asks = [...yesAsks];
  return {
    yesBids: bids,
    yesAsks: asks,
    noBids: asks
      .map((level) => ({ price: oneCollateral - level.price, quantity: level.quantity }))
      .sort((a, b) => (a.price === b.price ? 0 : a.price > b.price ? -1 : 1)),
    noAsks: bids
      .map((level) => ({ price: oneCollateral - level.price, quantity: level.quantity }))
      .sort((a, b) => (a.price === b.price ? 0 : a.price < b.price ? -1 : 1)),
  };
}

/** Return whether a current DreamDEX market matches an enabled series policy. */
export async function readPolicyEligibility(
  client: PublicClient,
  marketId: `0x${string}`,
): Promise<{ policyId: `0x${string}`; eligible: boolean }> {
  const result = (await client.readContract({
    ...controller,
    functionName: "policyFor",
    args: [marketId],
  })) as readonly [`0x${string}`, boolean];
  return { policyId: result[0], eligible: result[1] };
}

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
    risk: {
      maxDebtPerPosition: bigint;
      maxDebtPerOutcome: bigint;
      maxDebtPerMarket: bigint;
      maintenanceLtvBps: number | bigint;
    };
    enabled: boolean;
    frozen: boolean;
  };

  const registered = generation.key.pool !== "0x0000000000000000000000000000000000000000";

  return {
    registered,
    enabled: generation.enabled,
    frozen: generation.frozen,
    keyMatches: registered && marketKeysEqual(key, generation.key),
    maintenanceLtvBps: BigInt(generation.risk.maintenanceLtvBps),
    headroomCaps: registered
      ? {
          position: generation.risk.maxDebtPerPosition,
          outcome: generation.risk.maxDebtPerOutcome,
          market: generation.risk.maxDebtPerMarket,
        }
      : null,
  };
}

/** Read every owner position id through the controller's bounded pages. */
export async function readPositionIds(
  client: PublicClient,
  owner: Address,
  pageSize: number = DEPLOYMENT.maxPositionPageSize,
): Promise<bigint[]> {
  if (pageSize <= 0 || pageSize > DEPLOYMENT.maxPositionPageSize) {
    throw new Error(`position page size must be between 1 and ${DEPLOYMENT.maxPositionPageSize}`);
  }
  const ids: bigint[] = [];
  let total = 0n;

  do {
    const result = (await client.readContract({
      ...controller,
      functionName: "positionsOf",
      args: [owner, BigInt(ids.length), BigInt(pageSize)],
    })) as readonly [readonly bigint[], bigint];
    const [page, count] = result;
    total = count;
    ids.push(...page);
    if (page.length === 0) break;
  } while (BigInt(ids.length) < total);

  return ids;
}
