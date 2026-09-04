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
  /** Set when positions are sample data and cannot be acted on. */
  sample?: boolean;
};

export function PositionsView({
  snapshot,
  account = null,
  collateralAllowance = 0n,
  outcomeAllowance = 0n,
  onSettled,
  sample = false,
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

      {sample && account !== null ? (
        <p className="dm-empty-note">
          These are sample positions for layout. They do not exist on-chain, so their actions are
          disabled. Open a position from a market to see a real one here.
        </p>
      ) : null}

      {!sample && account !== null && ordered.length === 0 ? (
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
            outcomeAllowance={outcomeAllowance}
            onSettled={onSettled}
            sample={sample}
          />
        ))}
      </div>
    </div>
  );
}
