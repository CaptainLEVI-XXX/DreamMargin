import type { IndexPoint } from "../data/priceFeed";
import { formatCents, formatUnits } from "../domain/amounts";
import type { MarketView } from "../domain/models";
import { Countdown } from "./Countdown";
import { Sparkline } from "./Sparkline";
import { Value } from "./Value";

type Props = {
  market: MarketView;
  points: readonly IndexPoint[];
  chartState?: "loading" | "ready" | "error";
  onOpen: () => void;
};

/** How long the listed generation remains open. */
function intervalLabel(market: MarketView): string {
  const seconds = market.expiry - market.tradingStart;
  if (seconds >= 86_400n) return `${seconds / 86_400n} day market`;
  if (seconds >= 3_600n) return `${seconds / 3_600n} hour market`;
  return `${seconds / 60n} minute market`;
}

/** One whole-card navigation surface for a supported DreamDEX generation. */
export function MarketCard({ market, points, chartState, onOpen }: Props) {
  const held = market.ownedYes + market.ownedNo;
  const leveraged = market.maxLeverageBps > 10_000n;
  const rising = points.length > 1 && points[points.length - 1].close >= points[0].close;

  return (
    <button
      type="button"
      className="dm-market-card"
      onClick={onOpen}
      aria-label={`Open ${market.asset} market: ${market.question}`}
    >
      <span className="dm-market-card-top">
        <span>
          <span className="dm-market-symbol">{market.asset}</span>
          <span className="dm-market-interval">{intervalLabel(market)}</span>
        </span>
        <span className="dm-tag" data-on={leveraged ? "" : undefined}>
          {leveraged ? `up to ${Number(market.maxLeverageBps) / 10_000}x` : "buy only"}
        </span>
      </span>

      <span className="dm-market-question">{market.question}</span>

      <span className="dm-market-graph" data-up={rising ? "" : undefined}>
        <span className="dm-market-graph-label">Underlying · last 20m</span>
        {chartState === "loading" ? (
          <span className="dm-market-graph-loading">
            <span /> Loading underlying prices…
          </span>
        ) : (
          <Sparkline points={points} width={560} height={88} />
        )}
      </span>

      <span className="dm-market-prices">
        <span>
          <small>YES</small>
          <Value>{formatCents(market.yesPrice, market.oneCollateral)}</Value>
        </span>
        <span>
          <small>NO</small>
          <Value>{formatCents(market.oneCollateral - market.yesPrice, market.oneCollateral)}</Value>
        </span>
        <span className="dm-market-closes">
          <small>Closes in</small>
          <Countdown expiry={market.expiry} />
        </span>
      </span>

      <span className="dm-market-card-foot">
        <span>
          {held === 0n
            ? "No shares held"
            : `${formatUnits(held, market.collateralDecimals, 2)} shares held`}
        </span>
        <span className="dm-market-open">
          View market <span aria-hidden="true">→</span>
        </span>
      </span>
    </button>
  );
}
