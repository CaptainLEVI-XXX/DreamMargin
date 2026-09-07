import { formatUnits } from "../domain/amounts";
import type { Balances } from "../web3/tokens";
import { shortenAddress } from "../web3/wallet";
import { Card } from "./Card";
import { Value } from "./Value";

type Props = {
  account: string | null;
  balances: Balances;
  collateralDecimals: number;
  marketQuestion: string;
};

/**
 * What this wallet holds. §7.2 requires owned outcome shares to be visible
 * before any leverage action, since they are the equity a position is opened
 * against.
 */
export function BalancesPanel({ account, balances, collateralDecimals: d, marketQuestion }: Props) {
  if (account === null) {
    return (
      <Card title="Your balances">
        <p>Connect a wallet to view balances.</p>
      </Card>
    );
  }

  return (
    <Card title="Your balances">
      <p className="dm-balances-account">
        <Value>{shortenAddress(account)}</Value>
      </p>

      <dl className="dm-market-facts">
        <dt>tUSDC</dt>
        <dd>
          <Value>{formatUnits(balances.collateral, d)}</Value>
        </dd>
        <dt>Vault shares</dt>
        <dd>
          <Value>{formatUnits(balances.vaultShares, d)}</Value>
        </dd>
        <dt>YES shares</dt>
        <dd>
          <Value>{formatUnits(balances.yes, d)}</Value>
        </dd>
        <dt>NO shares</dt>
        <dd>
          <Value>{formatUnits(balances.no, d)}</Value>
        </dd>
      </dl>

      <p className="dm-balances-note">{marketQuestion}</p>
    </Card>
  );
}
