import { useState } from "react";
import { Button } from "../components/Button";
import { Card } from "../components/Card";
import { LeverageTiers } from "../components/LeverageTiers";
import { MarketChart } from "../components/MarketChart";
import { SafetyBuffer } from "../components/SafetyBuffer";
import { TransactionProgress } from "../components/TransactionProgress";
import { Value } from "../components/Value";
import { useIndexSeries } from "../data/useIndexSeries";
import type { Resolution } from "../data/priceFeed";
import { formatCents, formatUnits, parseUnitsStrict } from "../domain/amounts";
import { planAcquisition, type BookLevel } from "../domain/bookQuote";
import { defaultTier, formatMultiple, tiersFor } from "../domain/leverageTiers";
import type { MarketView, ProtocolView, VaultView } from "../domain/models";
import { availabilityFor, PositionStatus } from "../domain/protocol";
import type { WalletCapabilities } from "../transactions/callPlan";
import { planTrade } from "../transactions/tradePlan";
import { useIntentRunner } from "../transactions/useIntentRunner";
import { DEPLOYMENT } from "../config/deployment";
import type { Balances } from "../web3/tokens";

const BPS = 10_000n;
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
 * The tier row chooses the economic action. At 1x the entered size is a normal
 * outcome purchase. Above 1x the entered size is the exact final position:
 * DreamMargin combines trader tUSDC with vault debt and buys the outcome in one
 * controller action. The confirmation count always describes the current
 * review stage.
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
  const tiers = tiersFor(market.maxLeverageBps);
  const [side, setSide] = useState<"yes" | "no">("yes");
  const [leverageBps, setLeverageBps] = useState<bigint>(defaultTier(tiers));
  const [amountText, setAmountText] = useState("5");
  const [chartRange, setChartRange] = useState<ChartRange>("10d");
  const chart = CHART_RANGES[chartRange];
  const index = useIndexSeries(market.asset, market.tradingStart, chart.resolution, chart.limit);
  const { intent, run, reset } = useIntentRunner(account, capabilities, onSettled);

  let amount: bigint | null = null;
  try {
    amount = amountText.trim() === "" ? null : parseUnitsStrict(amountText, d);
  } catch {
    amount = null;
  }

  const owned = side === "yes" ? balances.yes : balances.no;
  const quantity = amount ?? 0n;
  const leveraged = leverageBps > BPS;
  const selectedLevels = side === "yes" ? book.asks : book.bids;
  const acquisition = planAcquisition({
    side,
    levels: selectedLevels,
    quantity: leveraged ? 0n : quantity,
    oneCollateral: market.oneCollateral,
    lotSize: 1_000n,
    allowMint: true,
  });

  /**
   * The deadline is supplied at click time, never at render: one computed while
   * the panel is merely on screen would already be stale by the time the user
   * acts, and §12 requires a quote whose deadline is still ahead of the
   * transaction.
   */
  const buildSequence = (deadlineSeconds: bigint) =>
    account === null || amount === null
      ? null
      : planTrade({
          market,
          side,
          quantity,
          leverageBps,
          acquisition,
          levels: selectedLevels,
          owned,
          collateralAllowance: balances.collateralAllowance,
          outcomeAllowance: side === "yes" ? balances.yesAllowance : balances.noAllowance,
          account,
          deadlineSeconds,
          lotSize: 1_000n,
          tickSize: 1_000n,
        });

  // Preview only: the confirmation count and borrow figure do not depend on the
  // deadline, so a placeholder keeps render pure.
  const sequence = buildSequence(0n);

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
  const selectedRiskMark = side === "yes" ? market.riskMark : market.noRiskMark;
  const maintenanceLtvBps = market.maintenanceLtvBps ?? 6_000n;
  const expectedRiskValue = (expectedExposure * selectedRiskMark) / market.oneCollateral;
  const expectedDebtCapacity = (expectedRiskValue * maintenanceLtvBps) / BPS;
  const expectedBufferBps =
    expectedDebtCapacity === 0n || borrowed >= expectedDebtCapacity
      ? 0n
      : ((expectedDebtCapacity - borrowed) * BPS) / expectedDebtCapacity;
  const expectedLiquidationPrice =
    expectedExposure === 0n || maintenanceLtvBps === 0n
      ? 0n
      : (borrowed * market.oneCollateral * BPS) / (expectedExposure * maintenanceLtvBps);
  // Borrowing draws on vault cash; without it the open reverts however many
  // shares are held, so it is surfaced here rather than at signing time.
  const vaultShort = leveraged && borrowed > vault.availableLiquidity;
  const totalCost = leveraged
    ? (sequence?.maximumCost ?? 0n)
    : acquisition.bookCost + acquisition.mintCost;
  const acquired = acquisition.fromBook + acquisition.fromMint;
  const effectivePrice = acquired === 0n ? null : (totalCost * market.oneCollateral) / acquired;

  const blockedReason = !leveraged
    ? undefined
    : vaultShort
      ? "The vault has no cash to lend"
      : availability.openBlockedReason;

  const canAct =
    account !== null && amount !== null && sequence !== null && sequence.blocked === undefined;

  return (
    <div className="dm-trade">
      <div className="dm-trade-context">
        {onBack === undefined ? null : (
          <button type="button" className="dm-back" onClick={onBack}>
            ← Markets
          </button>
        )}
        <h1>{market.question}</h1>
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
          <dt>Market price</dt>
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
            YES <Value>{formatCents(market.yesPrice, market.oneCollateral)}</Value>
          </button>
          <button
            type="button"
            className="dm-side-option"
            data-selected={side === "no" ? "" : undefined}
            aria-pressed={side === "no"}
            onClick={() => setSide("no")}
          >
            NO{" "}
            <Value>
              {formatCents(market.oneCollateral - market.yesPrice, market.oneCollateral)}
            </Value>
          </button>
        </div>

        <label className="dm-field">
          {leveraged ? "Position size in shares" : "Shares to buy"}
          <input
            aria-label="Shares"
            value={amountText}
            inputMode="decimal"
            onChange={(e) => setAmountText(e.target.value)}
          />
        </label>

        <div className="dm-chart-range dm-share-presets" role="group" aria-label="Share presets">
          {[100, 500, 1000].map((preset) => (
            <button key={preset} type="button" onClick={() => setAmountText(String(preset))}>
              {preset}
            </button>
          ))}
          <button
            type="button"
            onClick={() => setAmountText(formatUnits(DEPLOYMENT.maximumPositionShares, d, 0))}
          >
            Max
          </button>
        </div>

        <LeverageTiers
          maxLeverageBps={market.maxLeverageBps}
          selected={leverageBps}
          onSelect={setLeverageBps}
        />
        <p className="dm-step-note">
          {leveraged
            ? `Pay with tUSDC; DreamMargin adds vault credit and buys the ${side.toUpperCase()} shares in one transaction.`
            : `A normal DreamDEX purchase with no borrowing.`}
        </p>

        <dl className="dm-market-facts dm-trade-summary">
          {leveraged ? (
            <>
              <dt>Expected from wallet</dt>
              <dd>
                ≈ <Value>{formatUnits(sequence?.estimatedUserCollateral ?? 0n, d)} tUSDC</Value>
              </dd>
              <dt>Authorized maximum</dt>
              <dd>
                <Value>{formatUnits(sequence?.userCollateral ?? 0n, d)} tUSDC</Value>
              </dd>
              <dt>Vault credit</dt>
              <dd>
                ≈ <Value>{formatUnits(borrowed, d)} tUSDC</Value>
              </dd>
              <dt>Worst-case purchase cost</dt>
              <dd>
                <Value>{formatUnits(totalCost, d)} tUSDC</Value>
              </dd>
              <dt>Position exposure</dt>
              <dd>
                <Value>{formatUnits(expectedExposure, d)}</Value> {side.toUpperCase()}
              </dd>
            </>
          ) : (
            <>
              <dt>Cost</dt>
              <dd>
                <Value>{formatUnits(totalCost, d)} tUSDC</Value>
              </dd>
              <dt>Shares bought</dt>
              <dd>
                <Value>{formatUnits(acquired, d)}</Value> {side.toUpperCase()}
              </dd>
              <dt>Average price</dt>
              <dd>
                {/* The effective price differs whenever minting is involved:
                    a complete set costs one whole unit and also returns the
                    opposite outcome. */}
                {effectivePrice === null ? (
                  <span className="dm-unknown">—</span>
                ) : (
                  <Value>{formatCents(effectivePrice, market.oneCollateral)}</Value>
                )}
              </dd>
            </>
          )}
        </dl>

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

        <p className="dm-confirmations">
          {sequence === null
            ? "Connect a wallet to continue"
            : sequence.confirmations === 1
              ? "1 wallet confirmation"
              : `${sequence.confirmations} wallet confirmations`}
        </p>

        {intent === null ? (
          <Button
            variant="primary"
            disabled={!canAct || (leveraged && blockedReason !== undefined)}
            disabledReason={
              account === null
                ? "Connect a wallet to continue"
                : (blockedReason ?? sequence?.blocked)
            }
            onClick={() => {
              const fresh = buildSequence(nextTradeDeadline());
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
            {leveraged
              ? `Open ${formatMultiple(leverageBps)} position`
              : `Buy ${amountText} ${side.toUpperCase()}`}
          </Button>
        ) : (
          <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
        )}
      </Card>
    </div>
  );
}
