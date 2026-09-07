import { useState } from "react";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { Countdown } from "../components/Countdown";
import { LeverageTiers, type LeverageOption } from "../components/LeverageTiers";
import { MarketChart } from "../components/MarketChart";
import { SafetyBuffer } from "../components/SafetyBuffer";
import { TransactionProgress } from "../components/TransactionProgress";
import { Value } from "../components/Value";
import { useIndexSeries } from "../data/useIndexSeries";
import type { Resolution } from "../data/priceFeed";
import { formatCents, formatUnits, parseUnitsStrict } from "../domain/amounts";
import { planAcquisition, quoteSell, type BookLevel } from "../domain/bookQuote";
import { formatMultiple } from "../domain/leverageTiers";
import type { MarketView, ProtocolView, VaultView } from "../domain/models";
import { quotePayFirst } from "../domain/payFirstQuote";
import { availabilityFor, PositionStatus } from "../domain/protocol";
import type { WalletCapabilities } from "../transactions/callPlan";
import { planTrade } from "../transactions/tradePlan";
import { useIntentRunner } from "../transactions/useIntentRunner";
import { DEPLOYMENT } from "../config/deployment";
import type { Balances } from "../web3/tokens";

const BPS = 10_000n;
const PREVIEW_ACCOUNT = "0x0000000000000000000000000000000000000001" as const;
const MAX_LEVERAGE_CHOICE = "max";
const CLEAN_LEVERAGE_TARGETS = [10_000n, 12_500n, 15_000n, 17_500n] as const;
type ChartRange = "4h" | "10d" | "all";
const CHART_RANGES: Record<ChartRange, { label: string; resolution: Resolution; limit: number }> = {
  "4h": { label: "4H", resolution: "M1", limit: 240 },
  "10d": { label: "10D", resolution: "H1", limit: 240 },
  all: { label: "All", resolution: "D1", limit: 90 },
};

/** Build a short-lived venue deadline at the moment the user acts. */
function nextTradeDeadline(): bigint {
  return BigInt(Math.floor(Date.now() / 1000) + 60);
}

type Props = {
  market: MarketView;
  protocol: ProtocolView;
  vault: VaultView;
  balances: Balances;
  book: { asks: BookLevel[]; bids: BookLevel[] };
  account?: `0x${string}` | null;
  capabilities?: WalletCapabilities;
  onSettled?: () => void;
  onBack?: () => void;
  onSupplyVault?: () => void;
};

/**
 * The market page: chart on the left, one action panel on the right.
 *
 * The trader enters a wallet budget and chooses cash-on-cash leverage. The
 * client solves the corresponding shares and conservative contract risk value;
 * those implementation parameters never become part of the primary interface.
 */
export function TradeView({
  market,
  protocol,
  vault,
  balances,
  book,
  account = null,
  capabilities = { atomicBatch: false },
  onSettled,
  onBack,
  onSupplyVault,
}: Props) {
  const d = market.collateralDecimals;
  const [side, setSide] = useState<"yes" | "no">("yes");
  const [leverageChoice, setLeverageChoice] = useState("12500");
  const [amountText, setAmountText] = useState("50");
  const [chartRange, setChartRange] = useState<ChartRange>("10d");
  const chart = CHART_RANGES[chartRange];
  const index = useIndexSeries(market.asset, market.tradingStart, chart.resolution, chart.limit);
  const { intent, run, reset } = useIntentRunner(account, capabilities, onSettled);

  let walletBudget: bigint | null = null;
  try {
    walletBudget = amountText.trim() === "" ? null : parseUnitsStrict(amountText, d);
  } catch {
    walletBudget = null;
  }

  const owned = side === "yes" ? balances.yes : balances.no;
  const selectedLevels = side === "yes" ? book.asks : book.bids;
  const selectedRiskMark = side === "yes" ? market.riskMark : market.noRiskMark;
  const quoteFor = (targetLeverageBps?: bigint) =>
    quotePayFirst({
      side,
      levels: selectedLevels,
      walletBudget: walletBudget ?? 0n,
      targetLeverageBps,
      maxRiskLeverageBps: market.maxLeverageBps,
      riskMark: selectedRiskMark,
      oneCollateral: market.oneCollateral,
      lotSize: 1_000n,
      maximumShares: DEPLOYMENT.maximumPositionShares,
      authorizationBufferBps: market.oracleStale ? 1_000n : 100n,
    });
  const maximumQuote = quoteFor();
  const leverageOptions: LeverageOption[] = [{ id: String(BPS), label: "1x" }];
  for (const target of CLEAN_LEVERAGE_TARGETS.slice(1)) {
    if (target > maximumQuote.effectiveLeverageBps) continue;
    const quote = quoteFor(target);
    if (quote.blocked === undefined) {
      leverageOptions.push({ id: String(target), label: formatMultiple(target) });
    }
  }
  const highestClean = leverageOptions.at(-1);
  const highestCleanBps = highestClean === undefined ? BPS : BigInt(highestClean.id);
  if (
    maximumQuote.blocked === undefined &&
    maximumQuote.effectiveLeverageBps > highestCleanBps + 50n
  ) {
    leverageOptions.push({
      id: MAX_LEVERAGE_CHOICE,
      label: `Max ${formatMultiple(maximumQuote.effectiveLeverageBps)}`,
    });
  }
  const activeChoice = leverageOptions.some((option) => option.id === leverageChoice)
    ? leverageChoice
    : (leverageOptions.at(-1)?.id ?? String(BPS));
  const payQuote =
    activeChoice === MAX_LEVERAGE_CHOICE ? maximumQuote : quoteFor(BigInt(activeChoice));
  const quantity = payQuote.shares;
  const leveraged = payQuote.riskLeverageBps > BPS;
  const acquisition = planAcquisition({
    side,
    levels: selectedLevels,
    quantity,
    oneCollateral: market.oneCollateral,
    lotSize: 1_000n,
    allowMint: false,
  });

  /**
   * The deadline is supplied at click time, never at render: one computed while
   * the panel is merely on screen would already be stale by the time the user
   * acts, and §12 requires a quote whose deadline is still ahead of the
   * transaction.
   */
  const planSequence = (deadlineSeconds: bigint) =>
    walletBudget === null || payQuote.blocked !== undefined
      ? null
      : planTrade({
          market,
          side,
          quantity,
          leverageBps: payQuote.riskLeverageBps,
          acquisition,
          levels: selectedLevels,
          owned,
          collateralAllowance: balances.collateralAllowance,
          poolAllowance: balances.poolAllowance,
          outcomeAllowance: side === "yes" ? balances.yesAllowance : balances.noAllowance,
          account: account ?? PREVIEW_ACCOUNT,
          deadlineSeconds,
          lotSize: 1_000n,
          tickSize: 1_000n,
        });

  // Preview values do not depend on the deadline, so a placeholder keeps render pure.
  const sequence = planSequence(0n);

  const availability = availabilityFor({
    mode: protocol.mode,
    status: PositionStatus.Active,
    // Leveraged writes refresh a due sample in the same transaction.
    oracleStale: false,
    beforeOpeningCutoff: true,
    beforeReduceOnlyCutoff: true,
  });

  const borrowed = sequence?.borrowed ?? 0n;
  const financedShares = sequence?.financedShares ?? 0n;
  const expectedExposure = leveraged ? financedShares : 0n;
  const totalCost = payQuote.entryCost;
  const acquired = acquisition.fromBook + acquisition.fromMint;
  const walletPayment = payQuote.walletPayment;
  const receivedShares = leveraged ? expectedExposure : acquired;
  const estimatedLeverageBps = payQuote.effectiveLeverageBps;
  const estimatedDebt = totalCost > walletPayment ? totalCost - walletPayment : 0n;
  const exitQuote = quoteSell({
    side,
    levels: side === "yes" ? book.bids : book.asks,
    quantity: receivedShares,
    oneCollateral: market.oneCollateral,
    lotSize: 1_000n,
  });
  const exitIsFillable = receivedShares > 0n && exitQuote.fillable === receivedShares;
  const estimatedCloseReturn =
    exitIsFillable && exitQuote.proceeds > estimatedDebt ? exitQuote.proceeds - estimatedDebt : 0n;
  const spreadImpact =
    exitIsFillable && totalCost > exitQuote.proceeds ? totalCost - exitQuote.proceeds : 0n;
  const yesBuyPrice = book.asks[0]?.yesPrice;
  const yesSellPrice = book.bids[0]?.yesPrice;
  const noBuyPrice = yesSellPrice === undefined ? undefined : market.oneCollateral - yesSellPrice;
  const noSellPrice = yesBuyPrice === undefined ? undefined : market.oneCollateral - yesBuyPrice;
  const priceText = (price: bigint | undefined) =>
    price === undefined ? "Unavailable" : formatCents(price, market.oneCollateral);
  const maintenanceLtvBps = market.maintenanceLtvBps ?? 6_000n;
  const expectedRiskValue = (expectedExposure * selectedRiskMark) / market.oneCollateral;
  const expectedDebtCapacity = (expectedRiskValue * maintenanceLtvBps) / BPS;
  const expectedBufferBps =
    expectedDebtCapacity === 0n || estimatedDebt >= expectedDebtCapacity
      ? 0n
      : ((expectedDebtCapacity - estimatedDebt) * BPS) / expectedDebtCapacity;
  const expectedLiquidationPrice =
    expectedExposure === 0n || maintenanceLtvBps === 0n
      ? 0n
      : (estimatedDebt * market.oneCollateral * BPS) / (expectedExposure * maintenanceLtvBps);
  // Borrowing draws on vault cash; without it the open reverts however many
  // shares are held, so it is surfaced here rather than at signing time.
  const vaultShort = leveraged && borrowed > vault.availableLiquidity;
  const blockedReason =
    payQuote.blocked ??
    (leveraged
      ? vaultShort
        ? "The vault has no cash to lend"
        : availability.openBlockedReason
      : undefined);

  const canAct =
    account !== null &&
    walletBudget !== null &&
    payQuote.blocked === undefined &&
    sequence !== null &&
    sequence.blocked === undefined;

  return (
    <div className="dm-trade">
      <div className="dm-trade-context">
        {onBack === undefined ? null : (
          <button type="button" className="dm-back" onClick={onBack}>
            ← Markets
          </button>
        )}
        <div className="dm-trade-heading">
          <h1>{market.question}</h1>
          <div className="dm-trade-countdown" aria-label="Market time remaining">
            <span>Closes in</span>
            <Countdown expiry={market.expiry} includeSeconds />
          </div>
        </div>
        <div className="dm-chart-range" role="group" aria-label="Chart range">
          {(Object.entries(CHART_RANGES) as [ChartRange, (typeof CHART_RANGES)[ChartRange]][]).map(
            ([range, option]) => (
              <button
                key={range}
                type="button"
                data-selected={chartRange === range ? "" : undefined}
                onClick={() => setChartRange(range)}
              >
                {option.label}
              </button>
            ),
          )}
        </div>
        {index.kind === "ready" ? (
          <MarketChart series={index.series} strike={index.strike} asset={market.asset} />
        ) : (
          <div className="dm-chart dm-chart-empty">
            <p>
              {index.kind === "loading" ? "Loading price history…" : "Price history unavailable."}
            </p>
          </div>
        )}

        <dl className="dm-market-facts">
          <dt>Market midpoint</dt>
          <dd>
            {market.priceKnown === false ? (
              <span className="dm-unknown">No trades yet</span>
            ) : (
              <>
                <Value>{formatCents(market.yesPrice, market.oneCollateral)}</Value> YES
              </>
            )}
          </dd>
          <dt>{side.toUpperCase()} risk mark</dt>
          <dd>
            {/* §4.5 keeps market price and risk mark distinct. A stale oracle
                has no mark at all, so echoing the market price here would
                invent the very distinction the rule exists to preserve. */}
            {market.oracleStale ? (
              <span className="dm-unknown">Unavailable while risk data is stale</span>
            ) : (
              <Value>{formatCents(selectedRiskMark, market.oneCollateral)}</Value>
            )}
          </dd>
          <dt>You hold</dt>
          <dd>
            <Value>{formatUnits(balances.yes, d, 2)}</Value> YES ·{" "}
            <Value>{formatUnits(balances.no, d, 2)}</Value> NO
          </dd>
        </dl>
      </div>

      <Card title="Open position">
        <div className="dm-side">
          <button
            type="button"
            className="dm-side-option"
            data-selected={side === "yes" ? "" : undefined}
            aria-pressed={side === "yes"}
            onClick={() => setSide("yes")}
          >
            <span>YES</span>
            <span className="dm-side-quotes">
              <span>
                Buy <Value>{priceText(yesBuyPrice)}</Value>
              </span>
              <span>
                Sell <Value>{priceText(yesSellPrice)}</Value>
              </span>
            </span>
          </button>
          <button
            type="button"
            className="dm-side-option"
            data-selected={side === "no" ? "" : undefined}
            aria-pressed={side === "no"}
            onClick={() => setSide("no")}
          >
            <span>NO</span>
            <span className="dm-side-quotes">
              <span>
                Buy <Value>{priceText(noBuyPrice)}</Value>
              </span>
              <span>
                Sell <Value>{priceText(noSellPrice)}</Value>
              </span>
            </span>
          </button>
        </div>

        <label className="dm-field">
          Maximum spend
          <span className="dm-amount-input">
            <input
              aria-label="tUSDC amount"
              value={amountText}
              inputMode="decimal"
              onChange={(e) => setAmountText(e.target.value)}
            />
            <span>tUSDC</span>
          </span>
        </label>

        <div className="dm-chart-range dm-share-presets" role="group" aria-label="tUSDC presets">
          {[10, 50, 100].map((preset) => (
            <button key={preset} type="button" onClick={() => setAmountText(String(preset))}>
              {preset}
            </button>
          ))}
          <button
            type="button"
            onClick={() => setAmountText(formatUnits(balances.collateral, d, 2))}
          >
            Max
          </button>
        </div>

        <LeverageTiers
          options={leverageOptions}
          selected={activeChoice}
          onSelect={setLeverageChoice}
        />
        <p className="dm-step-note">
          {leveraged
            ? `Choose the position size you want without calculating the borrowing behind it.`
            : `Buy directly from the DreamDEX order book without borrowing.`}
        </p>

        <dl className="dm-market-facts dm-trade-summary">
          <dt>You pay</dt>
          <dd>
            <Value>{formatUnits(walletPayment, d, 2)} tUSDC</Value>
          </dd>
          <dt>You receive</dt>
          <dd>
            <Value>{formatUnits(receivedShares, d, 2)}</Value> {side.toUpperCase()}
          </dd>
          <dt>Position exposure</dt>
          <dd>
            <Value>{formatUnits(totalCost, d, 2)} tUSDC</Value>
          </dd>
          <dt>{leveraged ? "If closed now" : "If sold now"}</dt>
          <dd>
            {exitIsFillable ? (
              <Value>{formatUnits(estimatedCloseReturn, d, 2)} tUSDC</Value>
            ) : (
              <span className="dm-unknown">Not enough exit liquidity</span>
            )}
          </dd>
          <dt>Maximum payout</dt>
          <dd>
            <Value>{formatUnits(receivedShares, d, 2)} tUSDC</Value>
          </dd>
          <dt>Estimated leverage</dt>
          <dd>
            <Value>{formatMultiple(estimatedLeverageBps)}</Value>
          </dd>
        </dl>

        <details className="dm-order-details">
          <summary>Order details</summary>
          <dl className="dm-market-facts">
            {leveraged ? (
              <>
                <dt>Estimated debt</dt>
                <dd>
                  <Value>{formatUnits(estimatedDebt, d, 2)} tUSDC</Value>
                </dd>
                <dt>Maximum wallet spend</dt>
                <dd>
                  <Value>{formatUnits(payQuote.maximumWalletSpend, d, 2)} tUSDC</Value>
                </dd>
                <dt>Current spread impact</dt>
                <dd>
                  {exitIsFillable ? (
                    <Value>{formatUnits(spreadImpact, d, 2)} tUSDC</Value>
                  ) : (
                    <span className="dm-unknown">Unavailable</span>
                  )}
                </dd>
              </>
            ) : null}
          </dl>
        </details>

        {acquisition.note === undefined ? null : (
          <p className="dm-trade-note">{acquisition.note}</p>
        )}

        {leveraged ? (
          <SafetyBuffer
            bufferBps={expectedBufferBps}
            liquidationLabel={formatCents(expectedLiquidationPrice, market.oneCollateral)}
            updatedSecondsAgo={market.oracleUpdatedSecondsAgo}
            stale={market.oracleStale}
          />
        ) : null}

        {vaultShort ? (
          <p className="dm-trade-note">
            Leverage borrows from the vault, which has{" "}
            <Value>{formatUnits(vault.availableLiquidity, d)} tUSDC</Value> available.{" "}
            <button type="button" className="dm-inline-link" onClick={onSupplyVault}>
              Supply the vault
            </button>{" "}
            or choose 1x.
          </p>
        ) : null}

        {intent === null ? (
          <Button
            variant="primary"
            disabled={!canAct || blockedReason !== undefined}
            disabledReason={
              account === null
                ? "Connect a wallet to continue"
                : (blockedReason ?? sequence?.blocked)
            }
            onClick={() => {
              if (account === null) return;
              const fresh = planSequence(nextTradeDeadline());
              if (fresh === null) return;
              // Sequential by necessity: a DreamDEX fill must confirm before
              // DreamMargin can pull the shares.
              void (async () => {
                for (const next of fresh.intents) {
                  const result = await run(next);
                  if (result?.state.name !== "success") break;
                }
              })();
            }}
          >
            {leveraged ? `Open ${side.toUpperCase()} position` : `Buy ${side.toUpperCase()}`}
          </Button>
        ) : (
          <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
        )}
      </Card>
    </div>
  );
}
