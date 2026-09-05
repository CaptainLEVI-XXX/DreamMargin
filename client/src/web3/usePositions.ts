import { useCallback, useEffect, useState } from "react";
import type { Address } from "viem";
import { DEPLOYMENT } from "../config/deployment";
import type { MarketView, PositionView } from "../domain/models";
import { PositionStatus, type PositionStatusValue } from "../domain/protocol";
import { controllerAbi } from "./abis/controllerAbi";
import { vaultAbi } from "./abis/vaultAbi";
import { createReadClient } from "./client";
import { readPositionIds } from "./reads";

/**
 * The wallet's real positions.
 *
 * Ids come from the controller's bounded `positionsOf` pages, so an old position
 * remains visible without scanning millions of RPC-limited log blocks.
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

export function usePositions(account: Address | null, markets: readonly MarketView[]) {
  const [state, setState] = useState<PositionsState>({ kind: "idle" });
  const [version, setVersion] = useState(0);
  const refresh = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    if (account === null) return;
    let cancelled = false;

    void (async () => {
      try {
        const client = createReadClient();
        const ids = await readPositionIds(client, account);

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
        const debts = await Promise.all(
          raws.map((raw) => {
            const p = raw as unknown as RawPosition;
            return client.readContract({
              address: DEPLOYMENT.vault as Address,
              abi: vaultAbi,
              functionName: "debtAssets",
              args: [p.debtShares],
            });
          }),
        );

        const positions = raws
          .map((raw, i) => {
            const p = raw as unknown as RawPosition;
            const status = Number(p.status) as PositionStatusValue;
            const template = markets.find(
              (candidate) => candidate.key.marketId.toLowerCase() === p.marketId.toLowerCase(),
            );
            if (template === undefined) return null;
            const outcomeIndex = (p.outcomeIndex === 0 ? 0 : 1) as 0 | 1;
            const price =
              outcomeIndex === 0 ? template.yesPrice : template.oneCollateral - template.yesPrice;
            const mark =
              outcomeIndex === 0 ? template.riskMark : template.oneCollateral - template.riskMark;
            const debtAssets = debts[i];
            const riskValue = (p.shares * mark) / template.oneCollateral;
            const maintenanceLtvBps = template.maintenanceLtvBps ?? 6_000n;
            const debtCapacity = (riskValue * maintenanceLtvBps) / 10_000n;
            const bufferBps =
              debtCapacity === 0n || debtAssets >= debtCapacity
                ? 0n
                : ((debtCapacity - debtAssets) * 10_000n) / debtCapacity;
            const liquidationPrice =
              p.shares === 0n || maintenanceLtvBps === 0n
                ? 0n
                : (debtAssets * template.oneCollateral * 10_000n) / (p.shares * maintenanceLtvBps);
            return {
              positionId: ids[i],
              status,
              market: {
                ...template,
                key: {
                  ...template.key,
                  pool: p.pool,
                  outcomeToken: p.outcomeToken,
                  outcomeId: p.outcomeId,
                  marketNonce: p.marketNonce,
                },
              },
              outcomeIndex,
              shares: p.shares,
              debtAssets,
              equity: riskValue > debtAssets ? riskValue - debtAssets : 0n,
              marketValue: (p.shares * price) / template.oneCollateral,
              riskValue,
              unrealizedPnl: 0n,
              bufferBps,
              liquidationPrice,
              accruedFinancing: 0n,
              annualRateBps: 500n,
              openedAt: p.openedAt,
              riskIncreaseCutoff: p.expiry,
            };
          })
          .filter(
            (p): p is PositionView =>
              p !== null && p.status !== PositionStatus.None && p.status !== PositionStatus.Closed,
          );

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
  }, [account, markets, version]);

  return { state, refresh };
}
