import { useState } from "react";
import { BalancesPanel } from "../components/BalancesPanel";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { TransactionProgress } from "../components/TransactionProgress";
import { Value } from "../components/Value";
import { formatUnits, parseUnitsStrict } from "../domain/amounts";
import type { MarketView, VaultView } from "../domain/models";
import {
  buyOutcomeIntent,
  faucetIntent,
  mintSetIntent,
  vaultDepositIntent,
} from "../transactions/actions";
import type { WalletCapabilities } from "../transactions/callPlan";
import { useIntentRunner } from "../transactions/useIntentRunner";
import type { Balances } from "../web3/tokens";

type Props = {
  account: `0x${string}` | null;
  balances: Balances;
  market: MarketView;
  vault: VaultView;
  capabilities?: WalletCapabilities;
  onSettled?: () => void;
};

function useAmount(initial: string) {
  const [text, setText] = useState(initial);
  let parsed: bigint | null = null;
  try {
    parsed = text.trim() === "" ? null : parseUnitsStrict(text, 6);
  } catch {
    parsed = null;
  }
  return { text, setText, parsed };
}

/**
 * Bootstrap for a fresh testnet wallet, in the order the protocol actually
 * requires.
 *
 * Supplying the vault comes before opening leverage deliberately: borrowing
 * draws on vault cash, and with an empty vault `openPosition` reverts however
 * many shares the trader holds. Presenting the steps in any other order would
 * send people into a failure they cannot diagnose.
 */
export function GetStartedView({
  account,
  balances,
  market,
  vault,
  capabilities = { atomicBatch: false },
  onSettled,
}: Props) {
  const d = market.collateralDecimals;
  const pool = market.key.pool;
  const { intent, runningLabel, run, reset } = useIntentRunner(account, capabilities, onSettled);

  const faucet = useAmount("1000");
  const supply = useAmount("500");
  const mint = useAmount("100");
  const buy = useAmount("5");

  const connected = account !== null;
  const disabledReason = connected ? undefined : "Connect a wallet to continue";

  return (
    <div className="dm-getstarted">
      <BalancesPanel
        account={account}
        balances={balances}
        collateralDecimals={d}
        marketQuestion={market.question}
      />

      <Card title="Get started on Somnia Shannon">
        <div className="dm-step">
          <div className="dm-step-head">
            <span className="dm-step-title">1 · Mint test collateral</span>
            <span className="dm-step-note">
              Balance <Value>{formatUnits(balances.collateral, d)} tUSDC</Value>
            </span>
          </div>
          <p className="dm-step-note">tUSDC is a testnet token with no value.</p>
          <div className="dm-amount-row">
            <input
              aria-label="tUSDC to mint"
              value={faucet.text}
              onChange={(e) => faucet.setText(e.target.value)}
              inputMode="decimal"
            />
            <Button
              variant="secondary"
              disabled={!connected || faucet.parsed === null}
              disabledReason={disabledReason}
              onClick={() => faucet.parsed !== null && run(faucetIntent(faucet.parsed))}
            >
              Mint tUSDC
            </Button>
          </div>
        </div>

        <div className="dm-step">
          <div className="dm-step-head">
            <span className="dm-step-title">2 · Supply the vault</span>
            <span className="dm-step-note">
              Available to borrow <Value>{formatUnits(vault.availableLiquidity, d)} tUSDC</Value>
            </span>
          </div>
          <p className="dm-step-note">
            Leverage borrows vault cash. With an empty vault, opening a position reverts however
            many shares you hold. LP principal is at risk.
          </p>
          <div className="dm-amount-row">
            <input
              aria-label="tUSDC to supply"
              value={supply.text}
              onChange={(e) => supply.setText(e.target.value)}
              inputMode="decimal"
            />
            <Button
              variant="secondary"
              disabled={!connected || supply.parsed === null}
              disabledReason={disabledReason}
              onClick={() =>
                supply.parsed !== null &&
                account !== null &&
                run(vaultDepositIntent(supply.parsed, account, balances.collateralAllowance))
              }
            >
              Supply tUSDC
            </Button>
          </div>
        </div>

        <div className="dm-step">
          <div className="dm-step-head">
            <span className="dm-step-title">3 · Get outcome shares</span>
            <span className="dm-step-note">
              YES <Value>{formatUnits(balances.yes, d)}</Value> · NO{" "}
              <Value>{formatUnits(balances.no, d)}</Value>
            </span>
          </div>
          <p className="dm-step-note">
            Minting a complete set gives equal YES and NO for the collateral spent and needs no
            order-book liquidity. Buying takes one side only, but the book is thin.
          </p>
          <div className="dm-amount-row">
            <input
              aria-label="Complete sets to mint"
              value={mint.text}
              onChange={(e) => mint.setText(e.target.value)}
              inputMode="decimal"
            />
            <Button
              variant="secondary"
              disabled={!connected || mint.parsed === null}
              disabledReason={disabledReason}
              onClick={() =>
                mint.parsed !== null &&
                account !== null &&
                run(mintSetIntent(pool, mint.parsed, account))
              }
            >
              Mint complete sets
            </Button>
          </div>
          <div className="dm-amount-row">
            <input
              aria-label="YES shares to buy"
              value={buy.text}
              onChange={(e) => buy.setText(e.target.value)}
              inputMode="decimal"
            />
            <Button
              variant="secondary"
              disabled={!connected || buy.parsed === null}
              disabledReason={disabledReason}
              onClick={() =>
                buy.parsed !== null &&
                run(
                  buyOutcomeIntent({
                    pool,
                    side: "yes",
                    quantity: buy.parsed,
                    maxPrice: market.yesPrice,
                    oneCollateral: market.oneCollateral,
                    tickSize: 1_000n,
                    lotSize: 1_000n,
                    deadlineSeconds: BigInt(Math.floor(Date.now() / 1000) + 60),
                    collateralAllowance: balances.collateralAllowance,
                  }),
                )
              }
            >
              Buy YES on the book
            </Button>
          </div>
        </div>

        <div className="dm-step">
          <div className="dm-step-head">
            <span className="dm-step-title">4 · Open a leveraged position</span>
          </div>
          <p className="dm-step-note">
            With YES shares held, open an isolated position from the market builder.
          </p>
        </div>

        {intent === null ? null : (
          <>
            {runningLabel === null ? null : <p className="dm-step-note">{runningLabel}</p>}
            <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
          </>
        )}
      </Card>
    </div>
  );
}
