import { formatCents, formatUnits } from "../domain/amounts";
import type { PositionView } from "../domain/models";
import { availabilityFor, PositionStatus, type ProtocolModeValue } from "../domain/protocol";
import { Button } from "./Button";
import { Card } from "./Card";
import { TransactionProgress } from "./TransactionProgress";
import { SafetyBuffer } from "./SafetyBuffer";
import { Value } from "./Value";

import {
  addCollateralIntent,
  closeToOutcomeIntent,
  deleverageIntent,
  repayIntent,
  settleIntent,
} from "../transactions/actions";
import { useIntentRunner } from "../transactions/useIntentRunner";
import type { WalletCapabilities } from "../transactions/callPlan";

type Props = {
  position: PositionView;
  mode: ProtocolModeValue;
  primary: boolean;
  account?: `0x${string}` | null;
  /** Collateral allowance to the controller, deciding the confirmation count. */
  collateralAllowance?: bigint;
  outcomeAllowance?: bigint;
  capabilities?: WalletCapabilities;
  onSettled?: () => void;
};

/**
 * One position. §4.4: isolation is always stated. §4.3: repay is the primary
 * action on an unhealthy position and risk-reducing actions stay enabled in
 * every degraded protocol mode.
 */
export function PositionCard({
  position,
  mode,
  primary,
  account = null,
  collateralAllowance = 0n,
  outcomeAllowance = 0n,
  capabilities = { atomicBatch: false },
  onSettled,
}: Props) {
  const { market } = position;
  const { intent, run, reset } = useIntentRunner(account, capabilities, onSettled);
  const decimals = market.collateralDecimals;
  const availability = availabilityFor({
    mode,
    status: position.status,
    oracleStale: market.oracleStale,
    beforeOpeningCutoff: true,
    beforeReduceOnlyCutoff: true,
  });
  const resolved = position.status === PositionStatus.Resolved;

  // Every action signs against this exact position id, which the wallet must own.
  const actionBlocked = account === null ? "Connect a wallet to act on this position" : undefined;
  const usable = actionBlocked === undefined;

  return (
    <Card>
      <div className="dm-position-head">
        <h3>{market.question}</h3>
        <span className="dm-position-tag">
          {resolved ? "RESOLVED" : "ACTIVE"} · Isolated position
        </span>
      </div>

      <dl className="dm-position-facts">
        <dt>Shares</dt>
        <dd>
          <Value>{formatUnits(position.shares, decimals)} YES</Value>
        </dd>
        <dt>Outcome market value</dt>
        <dd>
          <Value>{formatUnits(position.marketValue, decimals)} tUSDC</Value>
        </dd>
        <dt>Conservative risk value</dt>
        <dd>
          <Value>{formatUnits(position.riskValue, decimals)} tUSDC</Value>
        </dd>
        <dt>Debt including charges</dt>
        <dd>
          <Value>{formatUnits(position.debtAssets, decimals)} tUSDC</Value>
        </dd>
      </dl>

      {resolved ? null : (
        <SafetyBuffer
          bufferBps={position.bufferBps}
          liquidationLabel={formatCents(position.liquidationPrice, market.oneCollateral)}
          updatedSecondsAgo={market.oracleUpdatedSecondsAgo}
          stale={market.oracleStale}
        />
      )}

      <p className="dm-isolated">
        Only the shares and collateral committed to this position secure its debt.
      </p>

      <div className="dm-position-actions">
        {resolved ? (
          <Button
            variant={primary ? "primary" : "secondary"}
            disabled={!availability.canSettle || !usable}
            disabledReason={actionBlocked}
            onClick={() => run(settleIntent(position.positionId))}
          >
            Settle position
          </Button>
        ) : (
          <>
            <Button
              variant={primary ? "primary" : "secondary"}
              disabled={!availability.canRepay || !usable}
              disabledReason={actionBlocked}
              onClick={() =>
                run(repayIntent(position.positionId, position.debtAssets, collateralAllowance))
              }
            >
              Repay
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canAddCollateral || !usable}
              disabledReason={actionBlocked}
              onClick={() =>
                run(
                  addCollateralIntent(
                    position.positionId,
                    market.ownedYes,
                    market.key.outcomeId,
                    outcomeAllowance,
                  ),
                )
              }
            >
              Add collateral
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canDeleverage || !usable}
              disabledReason={
                actionBlocked ??
                (availability.canDeleverage ? undefined : "Past the reduction cutoff")
              }
              onClick={() =>
                run(
                  deleverageIntent({
                    positionId: position.positionId,
                    sharesToSell: position.shares / 4n,
                    // Bounded by the conservative mark, not the visible price.
                    minCollateralOut:
                      ((position.shares / 4n) * market.riskMark) / market.oneCollateral,
                    limitPrice: market.riskMark,
                    deadlineSeconds: BigInt(Math.floor(Date.now() / 1000) + 60),
                    lotSize: 1_000n,
                  }),
                )
              }
            >
              Deleverage
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canClose || !usable}
              disabledReason={actionBlocked}
              onClick={() =>
                run(
                  closeToOutcomeIntent(
                    position.positionId,
                    position.debtAssets,
                    collateralAllowance,
                  ),
                )
              }
            >
              Repay and withdraw
            </Button>
          </>
        )}
      </div>

      {intent === null ? null : (
        <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
      )}
    </Card>
  );
}
