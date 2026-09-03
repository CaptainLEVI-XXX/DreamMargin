import { formatCents, formatUnits } from "../domain/amounts";
import type { PositionView } from "../domain/models";
import { availabilityFor, PositionStatus, type ProtocolModeValue } from "../domain/protocol";
import { Button } from "./Button";
import { Card } from "./Card";
import { SafetyBuffer } from "./SafetyBuffer";
import { Value } from "./Value";

type Props = { position: PositionView; mode: ProtocolModeValue; primary: boolean };

/**
 * One position. §4.4: isolation is always stated. §4.3: repay is the primary
 * action on an unhealthy position and risk-reducing actions stay enabled in
 * every degraded protocol mode.
 */
export function PositionCard({ position, mode, primary }: Props) {
  const { market } = position;
  const decimals = market.collateralDecimals;
  const availability = availabilityFor({
    mode,
    status: position.status,
    oracleStale: market.oracleStale,
    beforeOpeningCutoff: true,
    beforeReduceOnlyCutoff: true,
  });
  const resolved = position.status === PositionStatus.Resolved;

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
          <Button variant={primary ? "primary" : "secondary"} disabled={!availability.canSettle}>
            Settle position
          </Button>
        ) : (
          <>
            <Button variant={primary ? "primary" : "secondary"} disabled={!availability.canRepay}>
              Repay
            </Button>
            <Button variant="secondary" disabled={!availability.canAddCollateral}>
              Add collateral
            </Button>
            <Button
              variant="secondary"
              disabled={!availability.canDeleverage}
              disabledReason={availability.canDeleverage ? undefined : "Past the reduction cutoff"}
            >
              Deleverage
            </Button>
          </>
        )}
      </div>
    </Card>
  );
}
