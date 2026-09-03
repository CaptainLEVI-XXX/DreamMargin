import { formatCents, formatUnits } from "../domain/amounts";
import { availableCredit } from "../domain/credit";
import { formatMultiple } from "../domain/leverageTiers";
import type { MarketView } from "../domain/models";
import type { Availability } from "../domain/protocol";
import { Button } from "./Button";
import { Card } from "./Card";
import { Value } from "./Value";

type Props = {
  market: MarketView;
  availability: Availability;
  owned: bigint;
  primary: boolean;
  onUse: () => void;
};

/** Time remaining, rendered from the market's own clock rather than wall time. */
function timeRemaining(expiry: bigint, now: bigint): string {
  const seconds = expiry - now;
  if (seconds <= 0n) return "Trading closed";
  const hours = seconds / 3_600n;
  if (hours >= 24n) return `Ends in ${hours / 24n}d ${hours % 24n}h`;
  return `Ends in ${hours}h`;
}

/** One market, in frontend-spec §7.2's field order. */
export function MarketCard({ market, availability, owned, primary, onUse }: Props) {
  const credit = availableCredit(market.headroom);
  const noPrice = market.oneCollateral - market.yesPrice;

  return (
    <Card>
      <div className="dm-market-head">
        <h3>{market.question}</h3>
        <span className="dm-market-time">{timeRemaining(market.expiry, market.tradingStart)}</span>
      </div>

      <div className="dm-market-prices">
        <span>
          YES <Value>{formatCents(market.yesPrice, market.oneCollateral)}</Value>
        </span>
        <span>
          NO <Value>{formatCents(noPrice, market.oneCollateral)}</Value>
        </span>
      </div>

      <dl className="dm-market-facts">
        <dt>You own</dt>
        <dd>
          <Value>
            {owned === 0n ? "none" : `${formatUnits(owned, market.collateralDecimals)} YES`}
          </Value>
        </dd>
        <dt>Risk tier</dt>
        <dd>
          {market.riskTier} · up to <Value>{formatMultiple(market.maxLeverageBps)}</Value>
        </dd>
        <dt>Available to borrow</dt>
        <dd>
          <Value>{formatUnits(credit.available, market.collateralDecimals)} tUSDC</Value>
        </dd>
        <dt>Limited by</dt>
        <dd>{credit.explanation}</dd>
      </dl>

      <p className="dm-isolated">Isolated position</p>

      {owned > 0n ? (
        <Button
          variant={primary ? "primary" : "secondary"}
          disabled={!availability.canOpen}
          disabledReason={availability.openBlockedReason}
          onClick={onUse}
        >
          Use YES shares
        </Button>
      ) : (
        <Button variant="secondary" onClick={onUse}>
          View market
        </Button>
      )}
    </Card>
  );
}
