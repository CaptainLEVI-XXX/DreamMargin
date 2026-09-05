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
import { generationKey } from "../domain/marketKey";
import type { MarketView, ProtocolView, VaultView } from "../domain/models";
import { availabilityFor, PositionStatus } from "../domain/protocol";
import { observeIntent } from "../transactions/actions";
import type { WalletCapabilities } from "../transactions/callPlan";
import { planTrade } from "../transactions/tradePlan";
import { useIntentRunner } from "../transactions/useIntentRunner";
import type { Balances } from "../web3/tokens";

const BPS = 10_000n;
type ChartRange = "4h" | "10d" | "all";
const CHART_RANGES: Record<ChartRange, { label: string; resolution: Resolution; limit: number }> = {
  "4h": { label: "4H", resolution: "M1", limit: 240 },
  "10d": { label: "10D", resolution: "H1", limit: 240 },
  all: { label: "All", resolution: "D1", limit: 90 },
};

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
 * The tier row is the action rather than a separate step. At 1x this buys the
 * outcome and stops; above 1x it buys and then opens an isolated position
 * against the shares. Those remain two transactions, because a DreamDEX fill
 * must confirm before DreamMargin can pull the shares, but the trader makes one
 * decision instead of navigating two screens. The confirmation count is stated
 * before the first prompt so the extra step is never hidden.
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
  const acquisition = planAcquisition({
    side,
    levels: side === "yes" ? book.asks : book.bids,
    quantity: quantity > owned ? quantity - owned : 0n,
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
    oracleStale: market.oracleStale,
    beforeOpeningCutoff: true,
    beforeReduceOnlyCutoff: true,
  });

  const leveraged = leverageBps > BPS;
  const borrowed = sequence?.borrowed ?? 0n;
  // Borrowing draws on vault cash; without it the open reverts however many
  // shares are held, so it is surfaced here rather than at signing time.
  const vaultShort = leveraged && borrowed > vault.availableLiquidity;
  const totalCost = acquisition.bookCost + acquisition.mintCost;
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
          <dt>Risk mark</dt>
          <dd>
            {/* §4.5 keeps market price and risk mark distinct. A stale oracle
                has no mark at all, so echoing the market price here would
                invent the very distinction the rule exists to preserve. */}
            {market.oracleStale ? (
              <span className="dm-unknown">Unavailable while risk data is stale</span>
            ) : (
              <Value>{formatCents(market.riskMark, market.oneCollateral)}</Value>
            )}
          </dd>
          <dt>You hold</dt>
          <dd>
            <Value>{formatUnits(balances.yes, d, 2)}</Value> YES ·{" "}
            <Value>{formatUnits(balances.no, d, 2)}</Value> NO
          </dd>
        </dl>
      </div>

      <Card>
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
          Shares
          <input
            aria-label="Shares"
            value={amountText}
            inputMode="decimal"
            onChange={(e) => setAmountText(e.target.value)}
          />
        </label>

        <LeverageTiers
          maxLeverageBps={market.maxLeverageBps}
          selected={leverageBps}
          onSelect={setLeverageBps}
        />
        <p className="dm-step-note">
          {leveraged ? `Borrows to hold more than you pay for` : `Spot purchase, no borrowing`}
        </p>

        <dl className="dm-market-facts dm-trade-summary">
          <dt>Cost</dt>
          <dd>
            <Value>{formatUnits(acquisition.bookCost + acquisition.mintCost, d)} tUSDC</Value>
          </dd>
          {leveraged ? (
            <>
              <dt>Borrowed</dt>
              <dd>
                <Value>{formatUnits(borrowed, d)} tUSDC</Value>
              </dd>
              <dt>Position total</dt>
              <dd>
                <Value>{formatUnits(sequence?.committed ?? 0n, d)}</Value> {side.toUpperCase()}
              </dd>
            </>
          ) : null}
          <dt>Price paid</dt>
          <dd>
            {/* The effective price, which differs from the market price
                whenever any part is minted: a complete set always costs one
                whole unit however the book is priced. */}
            {effectivePrice === null ? (
              <span className="dm-unknown">—</span>
            ) : (
              <Value>{formatCents(effectivePrice, market.oneCollateral)}</Value>
            )}
          </dd>
        </dl>

        {acquisition.note === undefined ? null : (
          <p className="dm-trade-note">{acquisition.note}</p>
        )}

        {leveraged ? (
          <SafetyBuffer
            bufferBps={4_000n}
            liquidationLabel={formatCents(market.riskMark / 2n, market.oneCollateral)}
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

        {intent === null && leveraged && market.oracleStale ? (
          <Button
            variant="primary"
            disabled={account === null}
            disabledReason={account === null ? "Connect a wallet to continue" : undefined}
            onClick={() => run(observeIntent(generationKey(market.key)))}
          >
            Refresh risk data
          </Button>
        ) : intent === null ? (
          <Button
            variant="primary"
            disabled={!canAct || (leveraged && blockedReason !== undefined)}
            disabledReason={
              account === null
                ? "Connect a wallet to continue"
                : (blockedReason ?? sequence?.blocked)
            }
            onClick={() => {
              const fresh = buildSequence(BigInt(Math.floor(Date.now() / 1000) + 60));
              if (fresh === null) return;
              // Sequential by necessity: a DreamDEX fill must confirm before
              // DreamMargin can pull the shares.
              void (async () => {
                for (const next of fresh.intents) await run(next);
              })();
            }}
          >
            {leveraged
              ? `Buy ${amountText} ${side.toUpperCase()} at ${formatMultiple(leverageBps)}`
              : `Buy ${amountText} ${side.toUpperCase()}`}
          </Button>
        ) : (
          <TransactionProgress intent={intent} onReview={reset} onRetry={reset} />
        )}
      </Card>
    </div>
  );
}
