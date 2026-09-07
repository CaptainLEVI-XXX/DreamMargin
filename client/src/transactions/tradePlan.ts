import { erc20Abi, type Address } from "viem";
import { formatUnits, mulDivDown, mulDivUp } from "../domain/amounts";
import { quoteBuy, type AcquisitionPlan, type BookLevel } from "../domain/bookQuote";
import type { MarketView } from "../domain/models";
import {
  buyOutcomeIntent,
  MAX_UINT256,
  mintSetIntent,
  type Intent as ActionIntent,
} from "./actions";
import { buildCallPlan } from "./callPlan";
import { DEPLOYMENT } from "../config/deployment";
import { controllerAbi } from "../web3/abis/controllerAbi";

const BPS = 10_000n;
const FRESH_MARK_BUFFER_BPS = 100n;
const STALE_MARK_BUFFER_BPS = 1_000n;

/**
 * Compose one trade into the ordered intents it actually requires.
 *
 * At 1x the size is a normal DreamDEX purchase. Above 1x the controller pulls
 * tUSDC, borrows from the vault, buys the exact requested shares, and records
 * the position in one action. The owner never needs to pre-buy or approve
 * ERC-6909 outcome shares.
 */
export type TradeInput = {
  market: MarketView;
  side: "yes" | "no";
  /** Total shares to end up committing. */
  quantity: bigint;
  leverageBps: bigint;
  acquisition: AcquisitionPlan;
  /** Selected-side levels, best first, used only for the financed controller buy. */
  levels: readonly BookLevel[];
  owned: bigint;
  /** Allowance granted to the controller for leveraged opens. */
  collateralAllowance: bigint;
  /** Allowance granted to this market's pool for 1x purchases. */
  poolAllowance: bigint;
  outcomeAllowance: bigint;
  account: Address;
  deadlineSeconds: bigint;
  lotSize: bigint;
  tickSize: bigint;
};

export type TradeSequence = {
  stage: "spot" | "acquire" | "open";
  intents: ActionIntent[];
  /** Wallet confirmations for this stage, batching aside. */
  confirmations: number;
  /** Owner-supplied shares committed to a leveraged position. */
  committed: bigint;
  borrowed: bigint;
  /** Exact outcome shares bought into controller custody. */
  financedShares: bigint;
  /** Retained for spot/acquisition presentation; always zero for direct leverage. */
  missingShares: bigint;
  /** Maximum tUSDC pulled from the trader by the direct leveraged open. */
  userCollateral: bigint;
  /** Owner contribution estimated from the mark currently displayed. */
  estimatedUserCollateral: bigint;
  /** Worst-case collateral cost at the reviewed FOK limit. */
  maximumCost: bigint;
  /** Set when the size cannot be acquired at all. */
  blocked?: string;
};

type FinancingQuote = {
  borrowed: bigint;
  maxDebt: bigint;
  shares: bigint;
  userCollateral: bigint;
  estimatedUserCollateral: bigint;
  maximumCost: bigint;
  limitYesPrice: bigint;
  blocked?: string;
};

/**
 * Mirror the direct-open debt and owner-collateral bounds. The contract values
 * the exact target at the conservative mark, caps debt by both mark value and
 * acquisition cost, and sends any unused maximum cost back to the owner.
 */
function quoteFinancing(input: TradeInput): FinancingQuote {
  const { market } = input;
  const riskMark = input.side === "yes" ? market.riskMark : market.noRiskMark;
  if (input.quantity === 0n || input.quantity % input.lotSize !== 0n) {
    return {
      borrowed: 0n,
      maxDebt: 0n,
      shares: 0n,
      userCollateral: 0n,
      estimatedUserCollateral: 0n,
      maximumCost: 0n,
      limitYesPrice: 0n,
      blocked: "Enter a non-zero amount in whole market lots",
    };
  }
  if (input.quantity > DEPLOYMENT.maximumPositionShares) {
    return {
      borrowed: 0n,
      maxDebt: 0n,
      shares: input.quantity,
      userCollateral: 0n,
      estimatedUserCollateral: 0n,
      maximumCost: 0n,
      limitYesPrice: 0n,
      blocked: `The maximum position is ${formatUnits(DEPLOYMENT.maximumPositionShares, market.collateralDecimals)} shares`,
    };
  }
  const book = quoteBuy({
    side: input.side,
    levels: input.levels,
    quantity: input.quantity,
    oneCollateral: market.oneCollateral,
    lotSize: input.lotSize,
  });
  if (book.fillable !== input.quantity || book.limitYesPrice === 0n) {
    return {
      borrowed: 0n,
      maxDebt: 0n,
      shares: input.quantity,
      userCollateral: 0n,
      estimatedUserCollateral: 0n,
      maximumCost: 0n,
      limitYesPrice: book.limitYesPrice,
      blocked: "The order book cannot fill this exact position size",
    };
  }
  const sidePrice =
    input.side === "yes" ? book.limitYesPrice : market.oneCollateral - book.limitYesPrice;
  const grossValue = mulDivDown(input.quantity, riskMark, market.oneCollateral);
  const maximumCost = mulDivUp(input.quantity, sidePrice, market.oneCollateral);
  const valueEquity = mulDivUp(grossValue, BPS, input.leverageBps);
  const costEquity = mulDivUp(maximumCost, BPS, input.leverageBps);
  const valueDebt = grossValue > valueEquity ? grossValue - valueEquity : 0n;
  const costDebt = maximumCost > costEquity ? maximumCost - costEquity : 0n;
  const borrowed = valueDebt < costDebt ? valueDebt : costDebt;
  const estimatedUserCollateral = maximumCost - borrowed;
  // The write records a due oracle sample before recomputing the funding split.
  // Authorizing the exact pre-refresh number makes a one-unit mark change fail.
  // A fresh quote gets 1% of total cost; a stale quote gets 10% because its
  // displayed mark is the current executable recovery rather than retained TWAP.
  // Both limits remain capped by the cost-side leverage bound and total order cost.
  const bufferBps = market.oracleStale ? STALE_MARK_BUFFER_BPS : FRESH_MARK_BUFFER_BPS;
  const markBuffer = mulDivUp(maximumCost, bufferBps, BPS);
  const maxDebt = borrowed + markBuffer < costDebt ? borrowed + markBuffer : costDebt;
  const userCollateral =
    estimatedUserCollateral + markBuffer < maximumCost
      ? estimatedUserCollateral + markBuffer
      : maximumCost;
  return {
    borrowed,
    maxDebt,
    shares: input.quantity,
    userCollateral,
    estimatedUserCollateral,
    maximumCost,
    limitYesPrice: book.limitYesPrice,
  };
}

export function planTrade(input: TradeInput): TradeSequence {
  const { market, acquisition } = input;
  const intents: ActionIntent[] = [];
  const outcomeId = input.side === "yes" ? market.key.outcomeId : market.key.outcomeId + 1n;
  const leveraged = input.leverageBps > BPS;
  const acquired = acquisition.fromBook + acquisition.fromMint;

  if (!leveraged && input.quantity > 0n && acquired === 0n) {
    return {
      intents: [],
      stage: "spot",
      confirmations: 0,
      committed: 0n,
      borrowed: 0n,
      financedShares: 0n,
      missingShares: input.quantity,
      userCollateral: 0n,
      estimatedUserCollateral: 0n,
      maximumCost: 0n,
      blocked: "The book has no liquidity at this size and minting is unavailable",
    };
  }

  if (!leveraged && acquisition.fromBook > 0n) {
    intents.push(
      buyOutcomeIntent({
        pool: market.key.pool as Address,
        side: input.side,
        quantity: acquisition.fromBook,
        maxPrice:
          input.side === "yes"
            ? acquisition.limitYesPrice
            : market.oneCollateral - acquisition.limitYesPrice,
        oneCollateral: market.oneCollateral,
        tickSize: input.tickSize,
        lotSize: input.lotSize,
        deadlineSeconds: input.deadlineSeconds,
        collateralAllowance: input.poolAllowance,
      }),
    );
  }

  if (!leveraged && acquisition.fromMint > 0n) {
    intents.push(
      mintSetIntent(
        market.key.pool as Address,
        acquisition.fromMint,
        input.account,
        input.poolAllowance,
      ),
    );
  }

  if (!leveraged) {
    return {
      stage: "spot",
      intents,
      confirmations: intents.reduce((n, i) => n + i.plan.sequentialConfirmations, 0),
      committed: 0n,
      borrowed: 0n,
      financedShares: 0n,
      missingShares: 0n,
      userCollateral: acquisition.bookCost + acquisition.mintCost,
      estimatedUserCollateral: acquisition.bookCost + acquisition.mintCost,
      maximumCost: acquisition.bookCost + acquisition.mintCost,
    };
  }

  const financing = quoteFinancing(input);
  if (financing.blocked !== undefined) {
    return {
      stage: "open",
      intents: [],
      confirmations: 0,
      committed: input.quantity,
      borrowed: financing.borrowed,
      financedShares: financing.shares,
      missingShares: 0n,
      userCollateral: financing.userCollateral,
      estimatedUserCollateral: financing.estimatedUserCollateral,
      maximumCost: financing.maximumCost,
      blocked: financing.blocked,
    };
  }

  intents.push({
    label: `Open ${input.side.toUpperCase()} position`,
    plan: buildCallPlan({
      action: { to: DEPLOYMENT.controller as Address, label: "Open leveraged position" },
      erc20: {
        token: DEPLOYMENT.collateral as Address,
        spender: DEPLOYMENT.controller as Address,
        required: financing.userCollateral,
        current: input.collateralAllowance,
        approvalAmount: MAX_UINT256,
        label: "Enable tUSDC for DreamMargin",
      },
    }),
    reviewed: {
      side: "buy",
      maxCollateralIn: financing.userCollateral,
      minSharesOut: input.quantity,
      limitPrice: financing.limitYesPrice,
    },
    action: {
      address: DEPLOYMENT.controller as Address,
      abi: controllerAbi,
      functionName: "openFromCollateral",
      args: [
        {
          key: { ...market.key, outcomeId },
          outcomeIndex: input.side === "yes" ? 0 : 1,
          targetShares: input.quantity,
          leverageBps: input.leverageBps,
          maxUserCollateralIn: financing.userCollateral,
          maxDebt: financing.maxDebt,
          limitPrice: financing.limitYesPrice,
          deadline: input.deadlineSeconds,
        },
      ],
    },
    expectedEvent: "PositionOpened",
    approval: {
      address: DEPLOYMENT.collateral as Address,
      abi: erc20Abi,
      functionName: "approve",
      args: [DEPLOYMENT.controller, MAX_UINT256],
    },
  });

  return {
    stage: "open",
    intents,
    confirmations: intents.reduce((n, i) => n + i.plan.sequentialConfirmations, 0),
    committed: input.quantity,
    borrowed: financing.borrowed,
    financedShares: financing.shares,
    missingShares: 0n,
    userCollateral: financing.userCollateral,
    estimatedUserCollateral: financing.estimatedUserCollateral,
    maximumCost: financing.maximumCost,
  };
}
