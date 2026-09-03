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

export function PositionsView({ snapshot }: { snapshot: AppSnapshot }) {
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

      <div className="dm-position-list">
        {ordered.map((p, i) => (
          <PositionCard
            key={String(p.positionId)}
            position={p}
            mode={snapshot.protocol.mode}
            primary={i === 0}
          />
        ))}
      </div>
    </div>
  );
}
