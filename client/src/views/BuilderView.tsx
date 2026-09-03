import { useState } from "react";
import { Button } from "../components/Button";
import { TransactionProgress } from "../components/TransactionProgress";
import { Card } from "../components/Card";
import { LeverageTiers } from "../components/LeverageTiers";
import { SafetyBuffer } from "../components/SafetyBuffer";
import { Value } from "../components/Value";
import { formatCents, formatUnits, mulDivDown } from "../domain/amounts";
import { availableCredit } from "../domain/credit";
import { defaultTier, formatMultiple, tiersFor } from "../domain/leverageTiers";
import type { MarketView, ProtocolView } from "../domain/models";
import { availabilityFor, PositionStatus } from "../domain/protocol";
import { DEPLOYMENT } from "../config/deployment";
import type { Bounds } from "../transactions/bounds";
import {
  buildCallPlan,
  confirmationNotice,
  type WalletCapabilities,
} from "../transactions/callPlan";
import { createIntent, transition, type Intent } from "../transactions/machine";

const BPS = 10_000n;

type Props = {
  market: MarketView;
  protocol: ProtocolView;
  onBack: () => void;
  /** Detected at runtime; never assumed. §4.8 */
  capabilities?: WalletCapabilities;
  /** Current outcome allowance to the controller, in shares. */
  outcomeAllowance?: bigint;
};

/**
 * §8: context on the left, one action card on the right. The builder itself is
 * the review — there is no separate confirmation step before the wallet (§4.8),
 * and the action is labelled with the real intent rather than "Continue".
 *
 * Preview arithmetic here is display-only. Plan 3 replaces it with the contract
 * simulation, which remains the final admission check before any signature.
 */
export function BuilderView({
  market,
  protocol,
  onBack,
  capabilities = { atomicBatch: false },
  outcomeAllowance = 0n,
}: Props) {
  const tiers = tiersFor(market.maxLeverageBps);
  const [leverageBps, setLeverageBps] = useState<bigint>(defaultTier(tiers));
  const [intent, setIntent] = useState<Intent | null>(null);
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

  const minSharesOut = (expectedShares * 9_900n) / 10_000n;
  const plan = buildCallPlan({
    action: {
      to: DEPLOYMENT.controller as `0x${string}`,
      label: `Open ${formatMultiple(leverageBps)} position`,
    },
    erc6909: {
      token: DEPLOYMENT.outcomeToken as `0x${string}`,
      spender: DEPLOYMENT.controller as `0x${string}`,
      outcomeId: market.key.outcomeId,
      required: commit,
      current: outcomeAllowance,
      label: `Approve ${formatUnits(commit, decimals)} YES only`,
    },
  });

  /**
   * Exactly the numbers displayed above the action. The orchestrator compares a
   * refreshed request against these before requesting the second signature, and
   * stops for review if any of them worsened. §4.8
   */
  const reviewed: Bounds = {
    side: "buy",
    maxCollateralIn: borrowed,
    minSharesOut,
    limitPrice: market.yesPrice,
    minSafetyBufferBps: 4_000n,
  };

  const started = intent !== null && intent.state.name !== "idle";

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

        <dl className="dm-market-facts">
          <dt>Minimum received</dt>
          <dd>
            <Value>{formatUnits(minSharesOut, decimals)} YES</Value>
          </dd>
          <dt>Approval</dt>
          <dd>
            <Value>{formatUnits(commit, decimals)} YES</Value> only, outcome id{" "}
            <Value>{`…${market.key.outcomeId.toString().slice(-4)}`}</Value>
          </dd>
        </dl>

        <p className="dm-confirmations">{confirmationNotice(plan, capabilities)}</p>

        {started ? null : (
          <Button
            variant="primary"
            disabled={!availability.canOpen}
            disabledReason={availability.openBlockedReason}
            onClick={() =>
              setIntent(
                transition(transition(createIntent(reviewed), { type: "start" }), {
                  type: "plan-ready",
                  plan,
                  capabilities,
                }),
              )
            }
          >
            Add {formatMultiple(leverageBps)} leverage
          </Button>
        )}

        {intent === null ? null : (
          <TransactionProgress
            intent={intent}
            onReview={() => setIntent(null)}
            onRetry={() => setIntent(null)}
          />
        )}
      </Card>
    </div>
  );
}
