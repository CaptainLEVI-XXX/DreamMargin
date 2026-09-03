import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Value } from "../components/Value";
import { formatBps, formatUnits } from "../domain/amounts";
import type { VaultView } from "../domain/models";

/**
 * §12: simpler than a vault analytics dashboard, and honest that principal can
 * be lost. `maxWithdraw` is authoritative — never estimate an exit from total
 * assets. The borrower rate is never presented as realised LP yield.
 */
export function EarnView({ vault }: { vault: VaultView }) {
  const d = vault.collateralDecimals;

  return (
    <div className="dm-earn">
      <h1>Earn with dreammargin</h1>
      <p>
        Supply collateral to isolated dreamdex credit markets. LP principal is at risk when
        liquidations and reserves cannot cover borrower losses.
      </p>

      <div className="dm-earn-grid">
        <Card title="dreammargin tUSDC vault">
          <dl className="dm-market-facts">
            <dt>Total supplied</dt>
            <dd>
              <Value>{formatUnits(vault.totalAssets, d)} tUSDC</Value>
            </dd>
            <dt>Available cash</dt>
            <dd>
              <Value>{formatUnits(vault.availableLiquidity, d)} tUSDC</Value>
            </dd>
            <dt>Utilization</dt>
            <dd>
              <Value>{formatBps(vault.utilizationBps)}</Value>
            </dd>
            <dt>Locked reserve</dt>
            <dd>
              <Value>{formatUnits(vault.lockedReserve, d)} tUSDC</Value>
            </dd>
            <dt>Realized loss</dt>
            <dd>
              <Value>{formatUnits(vault.realizedBadDebt, d)} tUSDC</Value>
            </dd>
          </dl>
        </Card>

        <Card title="Supply tUSDC">
          <dl className="dm-market-facts">
            <dt>Your shares</dt>
            <dd>
              <Value>{formatUnits(vault.walletShares, d)}</Value>
            </dd>
            <dt>Withdrawable now</dt>
            <dd>
              <Value>{formatUnits(vault.maxWithdraw, d)} tUSDC</Value>
            </dd>
          </dl>
          <p className="dm-earn-note">Withdrawals depend on available vault cash.</p>
          <p className="dm-confirmations">2 wallet confirmations</p>
          <Button variant="primary">Supply 1,000 tUSDC</Button>
        </Card>
      </div>
    </div>
  );
}
