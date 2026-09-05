import { PositionCard } from "../components/PositionCard";
import { Value } from "../components/Value";
import { formatUnits } from "../domain/amounts";
import type { AppSnapshot, PositionView } from "../domain/models";
import { PositionStatus } from "../domain/protocol";

/** §10.2: order by required attention, never by notional value. */
function attentionRank(p: PositionView): number {
  if (p.bufferBps <= 0n) return 0;
  if (p.bufferBps < 1_000n) return 1;
  if (p.status === PositionStatus.Resolved) return 3;
  return 4;
}

type Props = {
  snapshot: AppSnapshot;
  account?: `0x${string}` | null;
  collateralAllowance?: bigint;
  outcomeAllowance?: bigint;
  onSettled?: () => void;
  /** True while positions are still being read from the chain. */
  loading?: boolean;
  error?: string;
};

export function PositionsView({
  snapshot,
  account = null,
  collateralAllowance = 0n,
  outcomeAllowance,
  onSettled,
  loading = false,
  error,
}: Props) {
  const ordered = [...snapshot.positions].sort((a, b) => attentionRank(a) - attentionRank(b));
  const decimals = snapshot.vault.collateralDecimals;
  const equity = ordered.reduce((sum, p) => sum + p.equity, 0n);
  const debt = ordered.reduce((sum, p) => sum + p.debtAssets, 0n);

  return (
    <div className="dm-positions">
      <h1>Your positions</h1>

      {/* §10.3: totals are summaries, never a cross-margin account. */}
      <div className="dm-totals">
        <span>
          Total equity <Value>{formatUnits(equity, decimals)} tUSDC</Value>
        </span>
        <span>
          Debt <Value>{formatUnits(debt, decimals)} tUSDC</Value>
        </span>
        <span>Isolated positions</span>
      </div>

      {account === null ? (
        <p className="dm-empty-note">
          Connect a wallet to see your positions. Repay, add collateral, and close act on your own
          positions, so they need a connected account.
        </p>
      ) : null}

      {loading && account !== null ? (
        <p className="dm-empty-note">Reading your positions from the chain…</p>
      ) : null}

      {error === undefined || account === null ? null : (
        <p className="dm-empty-note">Could not read your positions. {error}</p>
      )}

      {!loading && error === undefined && account !== null && ordered.length === 0 ? (
        <p className="dm-empty-note">
          No open positions. Buy an outcome on a market, then choose a multiple above 1x to open
          one.
        </p>
      ) : null}

      <div className="dm-position-list">
        {ordered.map((p, i) => (
          <PositionCard
            key={String(p.positionId)}
            position={p}
            mode={snapshot.protocol.mode}
            primary={i === 0}
            account={account}
            collateralAllowance={collateralAllowance}
            outcomeAllowance={
              outcomeAllowance ??
              (p.outcomeIndex === 0 ? (p.market.yesAllowance ?? 0n) : (p.market.noAllowance ?? 0n))
            }
            onSettled={onSettled}
          />
        ))}
      </div>
    </div>
  );
}
