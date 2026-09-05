import { useEffect, useState } from "react";
import type { Address } from "viem";
import { DEPLOYMENT } from "../config/deployment";
import type { CapHeadroom } from "../domain/credit";
import { generationKey } from "../domain/marketKey";
import type { MarketView } from "../domain/models";
import { createReadClient } from "./client";
import { deployedCandidates, leverageEligible, verifyMarkets } from "./discovery";
import {
  readBinaryBook,
  readOracle,
  readPolicyEligibility,
  type BinaryBook,
  type GenerationSnapshot,
} from "./reads";
import { EMPTY_BALANCES, readBalances } from "./tokens";

/**
 * The two dedicated DreamMargin markets, hydrated entirely from public on-chain
 * reads. The deployment manifest supplies identity; the controller, oracle,
 * pool, and ERC-6909 token supply mutable state. No private backend is needed.
 */

export type MarketsState =
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ready"; markets: MarketView[] };

function minimumCap(
  yes: GenerationSnapshot,
  no: GenerationSnapshot,
  name: keyof NonNullable<GenerationSnapshot["headroomCaps"]>,
): bigint {
  const a = yes.headroomCaps?.[name] ?? 0n;
  const b = no.headroomCaps?.[name] ?? 0n;
  return a < b ? a : b;
}

function headroom(yes: GenerationSnapshot, no: GenerationSnapshot): CapHeadroom {
  return {
    position: minimumCap(yes, no, "position"),
    outcome: minimumCap(yes, no, "outcome"),
    market: minimumCap(yes, no, "market"),
    global: 1_000_000_000n,
    utilization: 1_000_000_000n,
    vaultCash: 1_000_000_000n,
  };
}

function midPrice(book: BinaryBook, oneCollateral: bigint): { price: bigint; known: boolean } {
  const bid = book.yesBids[0]?.price;
  const ask = book.yesAsks[0]?.price;
  if (bid !== undefined && ask !== undefined) return { price: (bid + ask) / 2n, known: true };
  if (bid !== undefined) return { price: bid, known: true };
  if (ask !== undefined) return { price: ask, known: true };
  return { price: oneCollateral / 2n, known: false };
}

export function useMarkets(account: Address | null, refreshKey = 0): MarketsState {
  const key = `${account ?? "none"}|${refreshKey}`;
  const [entry, setEntry] = useState<{ key: string; state: MarketsState }>({
    key,
    state: { kind: "loading" },
  });

  useEffect(() => {
    let cancelled = false;

    void (async () => {
      try {
        const now = BigInt(Math.floor(Date.now() / 1000));
        const client = createReadClient();
        const verified = await verifyMarkets(client, deployedCandidates());

        const markets = await Promise.all(
          verified.map(async ({ candidate, yes, no }): Promise<MarketView> => {
            const [policy, oracle, book, balances] = await Promise.all([
              readPolicyEligibility(client, candidate.yesKey.marketId),
              readOracle(client, generationKey(candidate.yesKey), now),
              readBinaryBook(client, candidate.yesKey.pool as Address, candidate.oneCollateral),
              account === null
                ? Promise.resolve(EMPTY_BALANCES)
                : readBalances(
                    client,
                    account,
                    candidate.yesKey.outcomeId,
                    candidate.noKey.outcomeId,
                  ),
            ]);
            const quoted = midPrice(book, candidate.oneCollateral);
            const eligible =
              policy.eligible &&
              policy.policyId.toLowerCase() === DEPLOYMENT.seriesPolicyId.toLowerCase() &&
              leverageEligible(yes, candidate) &&
              leverageEligible(no, candidate);

            return {
              key: candidate.yesKey,
              question: candidate.question,
              asset: candidate.asset,
              expiry: candidate.expiry,
              tradingStart: candidate.tradingStart,
              oneCollateral: candidate.oneCollateral,
              collateralDecimals: candidate.collateralDecimals,
              yesPrice: quoted.price,
              priceKnown: quoted.known,
              riskMark: oracle.mark ?? quoted.price,
              estimatedExitValue: book.yesBids[0]?.price ?? 0n,
              maxLeverageBps: eligible ? 20_000n : 10_000n,
              maintenanceLtvBps: yes.maintenanceLtvBps,
              riskTier: eligible ? "Standard" : "Spot only",
              headroom: headroom(yes, no),
              visibleExitDepth: book.yesBids.reduce((sum, level) => sum + level.quantity, 0n),
              ownedYes: balances.yes,
              ownedNo: balances.no,
              yesAllowance: balances.yesAllowance,
              noAllowance: balances.noAllowance,
              oracleUpdatedSecondsAgo: oracle.updatedSecondsAgo,
              oracleStale: oracle.stale || oracle.mark === null,
              book,
            };
          }),
        );

        if (!cancelled) setEntry({ key, state: { kind: "ready", markets } });
      } catch (error) {
        if (!cancelled) {
          setEntry({
            key,
            state: {
              kind: "error",
              message:
                error instanceof Error ? error.message : "Could not read DreamMargin markets",
            },
          });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [account, key]);

  return entry.key === key ? entry.state : { kind: "loading" };
}
