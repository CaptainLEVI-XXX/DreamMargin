import { MarketCard } from "../components/MarketCard";
import type { AppSnapshot, MarketView } from "../domain/models";
import { availabilityFor, PositionStatus } from "../domain/protocol";

type Props = { snapshot: AppSnapshot; onOpenBuilder: (market: MarketView) => void };

/**
 * §7: what can I buy, and which owned outcomes can I use for leverage?
 * Owned outcomes come first; markets the user holds nothing in never show a
 * leverage call to action.
 */
export function MarketsView({ snapshot, onOpenBuilder }: Props) {
  const owned = snapshot.markets.filter((m) => m.ownedYes > 0n || m.ownedNo > 0n);
  const others = snapshot.markets.filter((m) => m.ownedYes === 0n && m.ownedNo === 0n);

  const availabilityOf = (m: MarketView) =>
    availabilityFor({
      mode: snapshot.protocol.mode,
      status: PositionStatus.Active,
      oracleStale: m.oracleStale,
      beforeOpeningCutoff: true,
      beforeReduceOnlyCutoff: true,
    });

  return (
    <div className="dm-markets">
      <h1>Markets</h1>
      <p>Use an eligible outcome you already own to open an isolated position.</p>

      <h2>Your eligible outcomes</h2>
      <div className="dm-market-list" data-testid="owned-markets">
        {owned.map((m, i) => (
          <MarketCard
            key={String(m.key.outcomeId)}
            market={m}
            availability={availabilityOf(m)}
            owned={m.ownedYes}
            primary={i === 0}
            onUse={() => onOpenBuilder(m)}
          />
        ))}
      </div>

      <h2>Other eligible markets</h2>
      <div className="dm-market-list" data-testid="other-markets">
        {others.map((m) => (
          <MarketCard
            key={String(m.key.outcomeId)}
            market={m}
            availability={availabilityOf(m)}
            owned={0n}
            primary={false}
            onUse={() => onOpenBuilder(m)}
          />
        ))}
      </div>
    </div>
  );
}
