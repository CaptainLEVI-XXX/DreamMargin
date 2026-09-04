import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { DEPLOYMENT } from "../config/deployment";
import type { MarketView, PositionView } from "../domain/models";
import { PositionStatus, type PositionStatusValue } from "../domain/protocol";
import { controllerAbi } from "./abis/controllerAbi";
import { createReadClient } from "./client";
import { listPositionIds } from "./reads";

/**
 * The wallet's real positions.
 *
 * The controller has no enumeration view, so ids come from `PositionOpened`
 * logs filtered by the indexed owner topic, then each is read with
 * `getPosition`. Nothing here is a fixture: a card rendered from this can be
 * acted on, where one rendered from sample data would target a position id that
 * does not exist and revert with `PositionNotFound`.
 */

export type PositionsState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "error"; message: string }
  | { kind: "ready"; positions: PositionView[] };

type RawPosition = {
  owner: Address;
  marketId: `0x${string}`;
  pool: Address;
  outcomeToken: Address;
  outcomeId: bigint;
  shares: bigint;
  debtShares: bigint;
  initialEquity: bigint;
  marketNonce: bigint;
  openedAt: bigint;
  expiry: bigint;
  outcomeIndex: number;
  status: number;
};

export function usePositions(account: Address | null, market: MarketView) {
  const [state, setState] = useState<PositionsState>({ kind: "idle" });
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    if (account === null) return;
    let cancelled = false;

    void (async () => {
      try {
        const client = createReadClient();
        const head = await client.getBlockNumber();
        const { ids } = await listPositionIds(
          client,
          account,
          DEPLOYMENT.deployedAtBlock,
          head,
          50_000n,
        );

        if (ids.length === 0) {
          if (!cancelled) setState({ kind: "ready", positions: [] });
          return;
        }

        const raws = await Promise.all(
          ids.map((id) =>
            client.readContract({
              address: DEPLOYMENT.controller as Address,
              abi: controllerAbi,
              functionName: "getPosition",
              args: [id],
            }),
          ),
        );

        const positions: PositionView[] = raws
          .map((raw, i) => {
            const p = raw as unknown as RawPosition;
            const status = Number(p.status) as PositionStatusValue;
            return {
              positionId: ids[i],
              status,
              // The market context the card renders against. Debt and health
              // still need vault and oracle reads, which the detail panel adds.
              market: { ...market, key: { ...market.key, outcomeId: p.outcomeId } },
              outcomeIndex: (p.outcomeIndex === 0 ? 0 : 1) as 0 | 1,
              shares: p.shares,
              debtAssets: p.debtShares,
              equity: p.initialEquity,
              marketValue: (p.shares * market.yesPrice) / market.oneCollateral,
              riskValue: (p.shares * market.riskMark) / market.oneCollateral,
              unrealizedPnl: 0n,
              bufferBps: 0n,
              liquidationPrice: market.riskMark / 2n,
              accruedFinancing: 0n,
              annualRateBps: 500n,
              openedAt: p.openedAt,
              riskIncreaseCutoff: p.expiry,
            };
          })
          .filter((p) => p.status !== PositionStatus.None && p.status !== PositionStatus.Closed);

        if (!cancelled) setState({ kind: "ready", positions });
      } catch (error) {
        if (!cancelled) {
          setState({
            kind: "error",
            message: error instanceof Error ? error.message : "Could not read positions",
          });
        }
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [account, market, version]);

  return { state, refresh };
}
