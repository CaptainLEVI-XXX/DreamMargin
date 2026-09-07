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
  const yesBuy = market.book?.yesAsks[0]?.price;
  const yesSell = market.book?.yesBids[0]?.price;
  const noBuy = market.book?.noAsks[0]?.price;
  const noSell = market.book?.noBids[0]?.price;
  const showPrice = (price: bigint | undefined) =>
    price === undefined ? "—" : formatCents(price, market.oneCollateral);

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
          {leveraged ? "leverage available" : "buy only"}
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
          <small>
            <span>YES</span> · BUY
          </small>
          <Value>{showPrice(yesBuy)}</Value>
          <span className="dm-market-sell">Sell {showPrice(yesSell)}</span>
        </span>
        <span>
          <small>
            <span>NO</span> · BUY
          </small>
          <Value>{showPrice(noBuy)}</Value>
          <span className="dm-market-sell">Sell {showPrice(noSell)}</span>
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
