import { formatCents, formatUnits } from "../domain/amounts";
import type { PositionView } from "../domain/models";
import { planDebtClearingDeleverage, repaymentLimit } from "../domain/positionManagement";
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
  withdrawCollateralIntent,
} from "../transactions/actions";
import { useIntentRunner } from "../transactions/useIntentRunner";
import type { WalletCapabilities } from "../transactions/callPlan";

type Props = {
  position: PositionView;
  mode: ProtocolModeValue;
  primary: boolean;
  account?: `0x${string}` | null;
  /** Collateral allowance to the controller, deciding whether approval is required. */
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
  const side = position.outcomeIndex === 0 ? "YES" : "NO";
  const walletOutcomeShares = position.outcomeIndex === 0 ? market.ownedYes : market.ownedNo;
  const maximumRepayment = repaymentLimit(position.debtAssets);
  const deleveragePlan = planDebtClearingDeleverage(position);

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
          <Value>
            {formatUnits(position.shares, decimals)} {side}
          </Value>
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
        ) : position.debtAssets === 0n ? (
          <Button
            variant={primary ? "primary" : "secondary"}
            disabled={!availability.canClose || !usable}
            disabledReason={actionBlocked}
            onClick={() => run(withdrawCollateralIntent(position.positionId, position.shares))}
          >
            Withdraw shares
          </Button>
        ) : (
          <>
            <Button
              variant={primary ? "primary" : "secondary"}
              disabled={!availability.canRepay || !usable}
              disabledReason={actionBlocked}
              onClick={() =>
                run(repayIntent(position.positionId, maximumRepayment, collateralAllowance))
              }
            >
              Repay
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canAddCollateral || !usable || walletOutcomeShares === 0n}
              disabledReason={
                actionBlocked ??
                (walletOutcomeShares === 0n
                  ? `No ${side} shares are available in this wallet`
                  : undefined)
              }
              onClick={() =>
                run(
                  addCollateralIntent(
                    position.positionId,
                    walletOutcomeShares,
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
              disabled={!availability.canDeleverage || !usable || !deleveragePlan.ready}
              disabledReason={
                actionBlocked ??
                (availability.canDeleverage
                  ? deleveragePlan.ready
                    ? undefined
                    : deleveragePlan.reason
                  : "Past the reduction cutoff")
              }
              onClick={() => {
                if (!deleveragePlan.ready) return;
                run(
                  deleverageIntent({
                    positionId: position.positionId,
                    sharesToSell: deleveragePlan.sharesToSell,
                    minCollateralOut: deleveragePlan.minCollateralOut,
                    limitPrice: deleveragePlan.limitPrice,
                    deadlineSeconds: BigInt(Math.floor(Date.now() / 1000) + 120),
                    lotSize: 1_000n,
                  }),
                );
              }}
            >
              Deleverage
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canClose || !usable}
              disabledReason={actionBlocked}
              onClick={() =>
                run(
                  closeToOutcomeIntent(position.positionId, maximumRepayment, collateralAllowance),
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
