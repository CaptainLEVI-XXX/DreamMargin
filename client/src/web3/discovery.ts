import type { PublicClient } from "viem";
import { DEPLOYMENT, MARKETS, type MarketDeployment } from "../config/deployment";
import type { MarketKey } from "../domain/models";
import { generationKey } from "../domain/marketKey";
import { readGeneration, type GenerationSnapshot } from "./reads";

/**
 * Market discovery.
 *
 * DreamMargin intentionally supports only its two long-lived demo markets.
 * Their identities come from the committed deployment manifest, then every
 * generation is verified on-chain before leverage is enabled. The client does
 * not need a private discovery service and cannot accidentally surface an
 * unrelated short-duration DreamDEX market.
 */

const MARKET_QUERY = `
  query DreamMarginMarkets($ids: [String!]) {
    Market(where: { marketId: { _in: $ids } }) {
      marketId
      marketAddress
      poolAddress
      nonce
      yesTokenId
      noTokenId
      collateral
      question
      asset
      expiry
      tradingStart
      clobStatus
      lastPrice
      quoteDecimals
    }
  }
`;

/** One market row exactly as the indexer returns it: every number is a string. */
export type IndexedMarket = {
  marketId: string;
  marketAddress: string;
  poolAddress: string;
  nonce: string;
  yesTokenId: string;
  noTokenId: string;
  collateral: string;
  question: string;
  asset: string;
  expiry: string;
  tradingStart: string;
  clobStatus: string;
  lastPrice: string | null;
  quoteDecimals: number;
};

export type MarketCandidate = {
  yesKey: MarketKey;
  noKey: MarketKey;
  question: string;
  asset: string;
  expiry: bigint;
  tradingStart: bigint;
  trading: boolean;
  /** YES price in collateral native units, or null when nothing has traded. */
  lastYesPrice: bigint | null;
  collateralDecimals: number;
  oneCollateral: bigint;
};

/** Convert one committed deployment entry into a market candidate. */
export function deployedCandidate(market: MarketDeployment): MarketCandidate {
  const base = {
    marketId: market.marketId,
    pool: market.pool,
    marketNonce: market.marketNonce,
    outcomeToken: DEPLOYMENT.outcomeToken,
    collateral: DEPLOYMENT.collateral,
  };
  const oneCollateral = 10n ** BigInt(DEPLOYMENT.collateralDecimals);

  return {
    yesKey: { ...base, outcomeId: market.yesId },
    noKey: { ...base, outcomeId: market.noId },
    question: market.question,
    asset: market.symbol,
    expiry: market.expiry,
    tradingStart: market.tradingStart,
    trading: market.expiry > BigInt(Math.floor(Date.now() / 1000)),
    lastYesPrice: null,
    collateralDecimals: DEPLOYMENT.collateralDecimals,
    oneCollateral,
  };
}

/** The complete client market universe; no indexer discovery is required. */
export function deployedCandidates(): MarketCandidate[] {
  return MARKETS.map(deployedCandidate);
}

/**
 * Convert an indexer row into candidate market keys.
 *
 * Every numeric field arrives as a string and becomes a bigint here. Token ids
 * exceed `Number.MAX_SAFE_INTEGER`, so passing one through `Number` would
 * silently corrupt market identity.
 */
export function toCandidate(row: IndexedMarket): MarketCandidate {
  const base = {
    marketId: row.marketId as `0x${string}`,
    pool: row.poolAddress as `0x${string}`,
    marketNonce: BigInt(row.nonce),
    // The outcome token is the single shared ERC-6909 contract from the
    // deployment, NOT the indexer's per-market `marketAddress`. Using the
    // latter derives a different generation key and would attach leverage to
    // the wrong identity.
    outcomeToken: DEPLOYMENT.outcomeToken as `0x${string}`,
    collateral: row.collateral as `0x${string}`,
  };

  return {
    yesKey: { ...base, outcomeId: BigInt(row.yesTokenId) },
    noKey: { ...base, outcomeId: BigInt(row.noTokenId) },
    question: row.question,
    asset: row.asset,
    expiry: BigInt(row.expiry),
    tradingStart: BigInt(row.tradingStart),
    trading: row.clobStatus === "Trading",
    lastYesPrice: row.lastPrice === null ? null : BigInt(row.lastPrice),
    collateralDecimals: row.quoteDecimals,
    oneCollateral: 10n ** BigInt(row.quoteDecimals),
  };
}

/** Fetch candidate markets from the indexer. */
export async function fetchMarkets(
  indexerUrl: string,
  marketIds: readonly string[],
  fetchImpl: typeof fetch = fetch,
): Promise<MarketCandidate[]> {
  const response = await fetchImpl(indexerUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: MARKET_QUERY, variables: { ids: marketIds } }),
  });

  if (!response.ok) throw new Error(`indexer returned ${response.status}`);

  const body = (await response.json()) as {
    data?: { Market?: IndexedMarket[] };
    errors?: { message: string }[];
  };

  if (body.errors !== undefined && body.errors.length > 0) {
    throw new Error(`indexer error: ${body.errors[0].message}`);
  }

  return (body.data?.Market ?? []).map(toCandidate);
}

export type VerifiedMarket = {
  candidate: MarketCandidate;
  yes: GenerationSnapshot;
  no: GenerationSnapshot;
};

/** True only when leverage may be offered on this outcome. §9.1 */
export function leverageEligible(
  generation: GenerationSnapshot,
  candidate: MarketCandidate,
): boolean {
  return (
    generation.registered &&
    generation.enabled &&
    !generation.frozen &&
    generation.keyMatches &&
    candidate.trading
  );
}

/**
 * Verify each candidate against the controller. The indexer may say a market
 * exists; only this decides whether leverage is offered on it.
 */
export async function verifyMarkets(
  client: PublicClient,
  candidates: readonly MarketCandidate[],
): Promise<VerifiedMarket[]> {
  return Promise.all(
    candidates.map(async (candidate) => ({
      candidate,
      yes: await readGeneration(client, candidate.yesKey),
      no: await readGeneration(client, candidate.noKey),
    })),
  );
}

export { generationKey };
