import type { Address } from "viem";
import { mulDivDown } from "../domain/amounts";
import type { AcquisitionPlan } from "../domain/bookQuote";
import type { MarketView } from "../domain/models";
import { buyOutcomeIntent, mintSetIntent, type Intent as ActionIntent } from "./actions";
import { buildCallPlan } from "./callPlan";
import { DEPLOYMENT } from "../config/deployment";
import { erc6909Abi } from "@somnia-chain/markets-sdk";

const BPS = 10_000n;

/**
 * Compose one trade into the ordered intents it actually requires.
 *
 * A trade is described by a side, a size, and a multiple. At 1x it is a
 * purchase and nothing more. Above 1x it is a purchase followed by opening an
 * isolated position against the resulting shares — still two transactions,
 * because the DreamDEX fill must confirm before DreamMargin can pull the
 * shares, but presented as one decision rather than two screens.
 *
 * Shares already held are used first, so a trader who owns the outcome does not
 * buy it again.
 */
export type TradeInput = {
  market: MarketView;
  side: "yes" | "no";
  /** Total shares to end up committing. */
  quantity: bigint;
  leverageBps: bigint;
  acquisition: AcquisitionPlan;
  owned: bigint;
  collateralAllowance: bigint;
  outcomeAllowance: bigint;
  account: Address;
  deadlineSeconds: bigint;
  lotSize: bigint;
  tickSize: bigint;
};

export type TradeSequence = {
  intents: ActionIntent[];
  /** Total wallet confirmations across the sequence, batching aside. */
  confirmations: number;
  /** Shares expected to be committed to the position. */
  committed: bigint;
  borrowed: bigint;
  /** Set when the size cannot be acquired at all. */
  blocked?: string;
};

export function planTrade(input: TradeInput): TradeSequence {
  const { market, acquisition } = input;
  const intents: ActionIntent[] = [];

  const needed = input.quantity > input.owned ? input.quantity - input.owned : 0n;
  const acquired = acquisition.fromBook + acquisition.fromMint;

  if (needed > 0n && acquired === 0n) {
    return {
      intents: [],
      confirmations: 0,
      committed: 0n,
      borrowed: 0n,
      blocked: "The book has no liquidity at this size and minting is unavailable",
    };
  }

  if (acquisition.fromBook > 0n) {
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
        collateralAllowance: input.collateralAllowance,
      }),
    );
  }

  if (acquisition.fromMint > 0n) {
    intents.push(mintSetIntent(market.key.pool as Address, acquisition.fromMint, input.account));
  }

  const committed = input.owned + acquired;
  const equity = mulDivDown(committed, market.riskMark, market.oneCollateral);
  const borrowed = mulDivDown(equity, input.leverageBps - BPS, BPS);

  if (input.leverageBps > BPS) {
    const minSharesOut =
      (mulDivDown(borrowed, market.oneCollateral, market.yesPrice) * 9_900n) / BPS;

    intents.push({
      label: `Open ${Number(input.leverageBps) / 10_000}x position`,
      plan: buildCallPlan({
        action: { to: DEPLOYMENT.controller as Address, label: "Open leveraged position" },
        erc6909: {
          token: DEPLOYMENT.outcomeToken as Address,
          spender: DEPLOYMENT.controller as Address,
          outcomeId: market.key.outcomeId,
          required: committed,
          current: input.outcomeAllowance,
          label: `Approve ${committed / market.oneCollateral} shares only`,
        },
      }),
      reviewed: {
        side: "buy",
        maxCollateralIn: borrowed,
        minSharesOut,
        limitPrice: market.yesPrice,
      },
      action: {
        address: DEPLOYMENT.controller as Address,
        abi: [],
        functionName: "openPosition",
        args: [
          {
            key: market.key,
            outcomeIndex: input.side === "yes" ? 0 : 1,
            initialShares: committed,
            leverageBps: input.leverageBps,
            maxCollateralIn: borrowed,
            minSharesOut,
            limitPrice: market.yesPrice,
            orderType: 2,
            deadline: input.deadlineSeconds,
          },
        ],
      },
      expectedEvent: "PositionOpened",
      approval: {
        address: DEPLOYMENT.outcomeToken as Address,
        abi: erc6909Abi as readonly unknown[],
        functionName: "approve",
        args: [DEPLOYMENT.controller, market.key.outcomeId, committed],
      },
    });
  }

  return {
    intents,
    confirmations: intents.reduce((n, i) => n + i.plan.sequentialConfirmations, 0),
    committed,
    borrowed: input.leverageBps > BPS ? borrowed : 0n,
  };
}
