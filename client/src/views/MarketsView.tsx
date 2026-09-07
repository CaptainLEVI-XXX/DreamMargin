import { MarketCard } from "../components/MarketCard";
import type { IndexPoint } from "../data/priceFeed";
import type { AppSnapshot, MarketView } from "../domain/models";

type Props = {
  snapshot: AppSnapshot;
  onOpenBuilder: (market: MarketView) => void;
  loading?: boolean;
  error?: string;
  /** Recent underlying movement, keyed by asset ticker. */
  sparks?: Record<string, IndexPoint[]>;
  sparkStates?: Record<string, "loading" | "ready" | "error">;
};

/**
 * Two deliberate market cards rather than a generic exchange table.
 *
 * DreamMargin currently supports exactly BTC and ETH. Giving each market a
 * full card makes the question, underlying movement, outcome prices, expiry,
 * and leverage eligibility understandable before the user enters trading.
 * The whole card is the navigation target; there is no redundant Trade button.
 */
export function MarketsView({
  snapshot,
  onOpenBuilder,
  loading,
  error,
  sparks = {},
  sparkStates = {},
}: Props) {
  const markets = [...snapshot.markets].sort((a, b) => a.asset.localeCompare(b.asset));

  return (
    <div className="dm-markets">
      <header className="dm-markets-heading">
        <div>
          <p className="dm-eyebrow">Live on DreamDEX</p>
          <h1>Choose a market</h1>
          <p className="dm-markets-lede">
            Take a side directly, or use vault credit for an isolated leveraged position.
          </p>
        </div>
        {markets.length === 0 ? null : (
          <span className="dm-market-count">
            <span aria-hidden="true" /> {markets.length} live
          </span>
        )}
      </header>

      {loading === true ? <p className="dm-empty-note">Finding markets…</p> : null}
      {error === undefined ? null : (
        <p className="dm-empty-note">Could not read the market contracts. {error}</p>
      )}
      {loading !== true && error === undefined && markets.length === 0 ? (
        <p className="dm-empty-note">No markets are trading right now.</p>
      ) : null}

      {markets.length === 0 ? null : (
        <div className="dm-market-grid">
          {markets.map((market) => (
            <MarketCard
              key={`${market.key.pool}-${market.key.outcomeId}`}
              market={market}
              points={sparks[market.asset] ?? []}
              chartState={sparkStates[market.asset]}
              onOpen={() => onOpenBuilder(market)}
            />
          ))}
        </div>
      )}
    </div>
  );
}
