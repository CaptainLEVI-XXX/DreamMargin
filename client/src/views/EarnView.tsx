import { useState } from "react";
import type { Address } from "viem";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { TransactionProgress } from "../components/TransactionProgress";
import { Value } from "../components/Value";
import { formatBps, formatUnits, parseUnitsStrict } from "../domain/amounts";
import type { VaultView } from "../domain/models";
import { vaultDepositIntent, vaultWithdrawIntent } from "../transactions/actions";
import { useIntentRunner } from "../transactions/useIntentRunner";
import { EMPTY_BALANCES, type Balances } from "../web3/tokens";

type Props = {
  vault: VaultView;
  account?: Address | null;
  balances?: Pick<Balances, "collateral" | "vaultAllowance">;
  onSettled?: () => void;
};

type VaultAction = "supply" | "withdraw";

/** ERC-4626 supply and cash-bounded withdrawal against authoritative vault reads. */
export function EarnView({ vault, account = null, balances = EMPTY_BALANCES, onSettled }: Props) {
  const d = vault.collateralDecimals;
  const [action, setAction] = useState<VaultAction>("supply");
  const [amountText, setAmountText] = useState("100");
  const { intent, run, reset } = useIntentRunner(account, { atomicBatch: false }, onSettled);

  let amount: bigint | null = null;
  try {
    amount = parseUnitsStrict(amountText, d);
  } catch {
    // The disabled action explains invalid input without mutating it.
  }

  const available = action === "supply" ? balances.collateral : vault.maxWithdraw;
  const unavailableReason =
    account === null
      ? "Connect a wallet to continue"
      : amount === null || amount === 0n
        ? "Enter a non-zero tUSDC amount"
        : amount > available
          ? action === "supply"
            ? "Amount exceeds your tUSDC balance"
            : "Amount exceeds what the vault can withdraw now"
          : undefined;

  const chooseAction = (next: VaultAction) => {
    reset();
    setAction(next);
    setAmountText(next === "supply" ? "100" : formatUnits(vault.maxWithdraw, d));
  };

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

        <Card title="Manage tUSDC">
          <div className="dm-vault-mode" role="group" aria-label="Vault action">
            <button
              type="button"
              data-selected={action === "supply" ? "" : undefined}
              onClick={() => chooseAction("supply")}
            >
              Supply
            </button>
            <button
              type="button"
              data-selected={action === "withdraw" ? "" : undefined}
              onClick={() => chooseAction("withdraw")}
            >
              Withdraw
            </button>
          </div>

          <dl className="dm-market-facts">
            <dt>Wallet balance</dt>
            <dd>
              <Value>{formatUnits(balances.collateral, d)} tUSDC</Value>
            </dd>
            <dt>Your vault shares</dt>
            <dd>
              <Value>{formatUnits(vault.walletShares, d)}</Value>
            </dd>
            <dt>Withdrawable now</dt>
            <dd>
              <Value>{formatUnits(vault.maxWithdraw, d)} tUSDC</Value>
            </dd>
          </dl>

          <label className="dm-field dm-vault-amount">
            tUSDC amount
            <input
              aria-label="tUSDC amount"
              inputMode="decimal"
              value={amountText}
              onChange={(event) => setAmountText(event.target.value)}
            />
          </label>
          <button
            type="button"
            className="dm-vault-max"
            onClick={() => setAmountText(formatUnits(available, d))}
          >
            Use max
          </button>

          <p className="dm-earn-note">
            {action === "supply"
              ? "Supplied tUSDC earns the vault rate while remaining subject to borrower losses."
              : "Withdrawals are limited to your assets and the vault's immediately available cash."}
          </p>

          {intent === null ? (
            <Button
              variant="primary"
              disabled={unavailableReason !== undefined}
              disabledReason={unavailableReason}
              onClick={() => {
                if (account === null || amount === null || amount === 0n) return;
                run(
                  action === "supply"
                    ? vaultDepositIntent(amount, account, balances.vaultAllowance)
                    : vaultWithdrawIntent(amount, account),
                );
              }}
            >
              {action === "supply" ? `Supply ${amountText || "0"} tUSDC` : "Withdraw tUSDC"}
            </Button>
          ) : (
            <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
          )}
        </Card>
      </div>
    </div>
  );
}
