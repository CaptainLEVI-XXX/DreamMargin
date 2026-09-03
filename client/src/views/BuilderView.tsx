import { useState } from "react";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { LeverageTiers } from "../components/LeverageTiers";
import { SafetyBuffer } from "../components/SafetyBuffer";
import { Value } from "../components/Value";
import { formatCents, formatUnits, mulDivDown } from "../domain/amounts";
import { availableCredit } from "../domain/credit";
import { defaultTier, formatMultiple, tiersFor } from "../domain/leverageTiers";
import type { MarketView, ProtocolView } from "../domain/models";
import { availabilityFor, PositionStatus } from "../domain/protocol";

const BPS = 10_000n;

type Props = { market: MarketView; protocol: ProtocolView; onBack: () => void };

/**
 * §8: context on the left, one action card on the right. The builder itself is
 * the review — there is no separate confirmation step before the wallet (§4.8),
 * and the action is labelled with the real intent rather than "Continue".
 *
 * Preview arithmetic here is display-only. Plan 3 replaces it with the contract
 * simulation, which remains the final admission check before any signature.
 */
export function BuilderView({ market, protocol, onBack }: Props) {
  const tiers = tiersFor(market.maxLeverageBps);
  const [leverageBps, setLeverageBps] = useState<bigint>(defaultTier(tiers));
  const decimals = market.collateralDecimals;

  const commit = market.ownedYes;
  const equity = mulDivDown(commit, market.riskMark, market.oneCollateral);
  const borrowed = mulDivDown(equity, leverageBps - BPS, BPS);
  const credit = availableCredit(market.headroom);
  const expectedShares =
    market.yesPrice === 0n ? 0n : mulDivDown(borrowed, market.oneCollateral, market.yesPrice);
  const totalShares = commit + expectedShares;

  const availability = availabilityFor({
    mode: protocol.mode,
    status: PositionStatus.Active,
    oracleStale: market.oracleStale,
    beforeOpeningCutoff: true,
    beforeReduceOnlyCutoff: true,
  });

  return (
    <div className="dm-builder">
      <div className="dm-builder-context">
        <Button variant="tertiary" onClick={onBack}>
          ← Markets
        </Button>
        <h1>{market.question}</h1>

        <div className="dm-builder-price">
          <Value>{formatCents(market.yesPrice, market.oneCollateral)}</Value>
          <span>Market price</span>
        </div>

        <dl className="dm-market-facts">
          <dt>Risk mark</dt>
          <dd>
            <Value>{formatCents(market.riskMark, market.oneCollateral)}</Value>
          </dd>
          <dt>Estimated exit value</dt>
          <dd>
            <Value>{formatCents(market.estimatedExitValue, market.oneCollateral)}</Value>
          </dd>
          <dt>Available to borrow</dt>
          <dd>
            <Value>{formatUnits(credit.available, decimals)} tUSDC</Value>
          </dd>
          <dt>Limited by</dt>
          <dd>{credit.explanation}</dd>
        </dl>
      </div>

      <Card title="Open isolated position">
        <p className="dm-owned">
          You own <Value>{formatUnits(commit, decimals)} YES</Value>
        </p>

        <LeverageTiers
          maxLeverageBps={market.maxLeverageBps}
          selected={leverageBps}
          onSelect={setLeverageBps}
        />

        <dl className="dm-market-facts dm-builder-summary">
          <dt>You commit</dt>
          <dd>
            <Value>{formatUnits(commit, decimals)} YES</Value>
          </dd>
          <dt>Borrowed</dt>
          <dd>
            <Value>{formatUnits(borrowed, decimals)} tUSDC</Value>
          </dd>
          <dt>Expected buy</dt>
          <dd>
            <Value>{formatUnits(expectedShares, decimals)} YES</Value>
          </dd>
          <dt>Position total</dt>
          <dd>
            <Value>{formatUnits(totalShares, decimals)} YES</Value>
          </dd>
          <dt>Effective leverage</dt>
          <dd>
            <Value>{formatMultiple(leverageBps)}</Value>
          </dd>
        </dl>

        <SafetyBuffer
          bufferBps={4_000n}
          liquidationLabel={formatCents(480_000n, market.oneCollateral)}
          updatedSecondsAgo={market.oracleUpdatedSecondsAgo}
          stale={market.oracleStale}
        />

        <p className="dm-at-risk">
          At risk: the committed shares and any optional top-up. If YES loses value, they may be
          liquidated. Binary markets can move directly toward zero.
        </p>

        <p className="dm-confirmations">2 wallet confirmations</p>

        <Button
          variant="primary"
          disabled={!availability.canOpen}
          disabledReason={availability.openBlockedReason}
        >
          Add {formatMultiple(leverageBps)} leverage
        </Button>
      </Card>
    </div>
  );
}
