import { erc20Abi, parseAbi, type Address } from "viem";
import { erc6909Abi } from "@somnia-chain/markets-sdk";
import { DEPLOYMENT } from "../config/deployment";
import { formatUnits, quantizeDown, quantizeUp } from "../domain/amounts";
import { oracleAbi } from "../web3/abis/oracleAbi";

import type { Bounds } from "./bounds";
import { buildCallPlan, type CallPlan } from "./callPlan";

/**
 * Every economic intent the client can start, expressed as a call plan plus the
 * bounds the user reviewed.
 *
 * One place for all of them so approval scope, exactness, and the reviewed set
 * are decided uniformly rather than per screen. §17.2: approvals are always the
 * exact amount and, for outcomes, the exact id.
 */

export const testUsdcAbi = parseAbi(["function faucet(uint256 amount)"]);

export const binaryPoolAbi = parseAbi([
  "function mintSet(address yesTo, address noTo, uint256 amount)",
  "function placeBinaryOrder(uint8 kind, uint128 limitPrice, uint128 quantity, uint64 deadlineNs, uint8 orderType, uint8 selfMatch, address builder, uint16 builderFeeBps, bytes userData) returns (uint256)",
]);

/** tUSDC and outcome shares both use six decimals on this deployment. */
const DECIMALS = 6;

/** Format an amount for a label. Integer division would silently truncate. */
function amt(value: bigint): string {
  return formatUnits(value, DECIMALS, 2);
}

const controller = DEPLOYMENT.controller as Address;
const collateral = DEPLOYMENT.collateral as Address;
const outcomeToken = DEPLOYMENT.outcomeToken as Address;
const vault = DEPLOYMENT.vault as Address;

/** DreamDEX order kinds. Only immediate orders are used. */
export const OrderKind = { BuyYes: 0, SellYes: 1, BuyNo: 2, SellNo: 3 } as const;
/** 1 = FOK, 2 = IOC. DreamMargin writes permit only these. */
export const OrderType = { Fok: 1, Ioc: 2 } as const;

export type Action = {
  address: Address;
  abi: readonly unknown[];
  functionName: string;
  args: readonly unknown[];
};

export type Intent = {
  label: string;
  plan: CallPlan;
  reviewed: Bounds;
  action: Action;
  /** Protocol event that must appear for this to count as done. */
  expectedEvent?: string;
  approval?: Action;
};

/** Mint test collateral. Testnet only, and it needs no approval. */
export function faucetIntent(amount: bigint): Intent {
  return {
    label: `Mint ${amt(amount)} tUSDC`,
    plan: buildCallPlan({ action: { to: collateral, label: `Mint tUSDC` } }),
    reviewed: {},
    action: { address: collateral, abi: testUsdcAbi, functionName: "faucet", args: [amount] },
  };
}

/** Record a permissionless oracle sample when a quiet market has gone stale. */
export function observeIntent(generationKey: `0x${string}`): Intent {
  return {
    label: "Refresh risk data",
    plan: buildCallPlan({
      action: { to: DEPLOYMENT.oracle as Address, label: "Refresh risk data" },
    }),
    reviewed: {},
    action: {
      address: DEPLOYMENT.oracle as Address,
      abi: oracleAbi,
      functionName: "observe",
      args: [generationKey],
    },
  };
}

/**
 * Mint a complete set: `amount` collateral becomes `amount` YES *and* `amount`
 * NO. This needs no order-book liquidity, which matters because the book holds
 * only a handful of shares — so it is the reliable way to obtain the outcome
 * shares a leveraged position is opened against.
 */
export function mintSetIntent(pool: Address, amount: bigint, to: Address): Intent {
  return {
    label: `Mint ${amt(amount)} complete sets`,
    plan: buildCallPlan({
      action: { to: pool, label: "Mint complete set" },
      erc20: {
        token: collateral,
        spender: pool,
        required: amount,
        current: 0n,
        label: `Approve ${amt(amount)} tUSDC`,
      },
    }),
    reviewed: { maxCollateralIn: amount },
    action: {
      address: pool,
      abi: binaryPoolAbi,
      functionName: "mintSet",
      args: [to, to, amount],
    },
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [pool, amount],
    },
  };
}

/**
 * Buy one outcome directly on the book.
 *
 * Prices are always expressed in the YES convention, so a NO buy sets its
 * threshold as `oneCollateral - maxNoPrice`. Quantity rounds down to the lot and
 * the YES-price bound rounds so the user's ceiling cannot be exceeded in either
 * direction.
 */
export function buyOutcomeIntent(input: {
  pool: Address;
  side: "yes" | "no";
  quantity: bigint;
  maxPrice: bigint;
  oneCollateral: bigint;
  tickSize: bigint;
  lotSize: bigint;
  deadlineSeconds: bigint;
  collateralAllowance: bigint;
}): Intent {
  const quantity = quantizeDown(input.quantity, input.lotSize);
  const yesLimit =
    input.side === "yes"
      ? quantizeDown(input.maxPrice, input.tickSize)
      : quantizeUp(input.oneCollateral - input.maxPrice, input.tickSize);

  const maxCollateralIn =
    (quantity * (input.side === "yes" ? yesLimit : input.oneCollateral - yesLimit)) /
    input.oneCollateral;

  return {
    label: `Buy ${amt(quantity)} ${input.side.toUpperCase()}`,
    plan: buildCallPlan({
      action: { to: input.pool, label: `Buy ${input.side.toUpperCase()}` },
      erc20: {
        token: collateral,
        spender: input.pool,
        required: maxCollateralIn,
        current: input.collateralAllowance,
        label: `Approve ${amt(maxCollateralIn)} tUSDC`,
      },
    }),
    reviewed: { side: "buy", maxCollateralIn, limitPrice: yesLimit },
    action: {
      address: input.pool,
      abi: binaryPoolAbi,
      functionName: "placeBinaryOrder",
      args: [
        input.side === "yes" ? OrderKind.BuyYes : OrderKind.BuyNo,
        yesLimit,
        quantity,
        input.deadlineSeconds * 1_000_000_000n,
        OrderType.Ioc,
        0,
        "0x0000000000000000000000000000000000000000",
        0,
        "0x",
      ],
    },
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [input.pool, maxCollateralIn],
    },
  };
}

/** Supply collateral to the vault. ERC-4626 deposit. */
export function vaultDepositIntent(assets: bigint, receiver: Address, allowance: bigint): Intent {
  return {
    label: `Supply ${amt(assets)} tUSDC`,
    plan: buildCallPlan({
      action: { to: vault, label: "Supply to vault" },
      erc20: {
        token: collateral,
        spender: vault,
        required: assets,
        current: allowance,
        label: `Approve ${amt(assets)} tUSDC`,
      },
    }),
    reviewed: { maxCollateralIn: assets },
    action: {
      address: vault,
      abi: parseAbi(["function deposit(uint256 assets, address receiver) returns (uint256)"]),
      functionName: "deposit",
      args: [assets, receiver],
    },
    expectedEvent: "Deposit",
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [vault, assets],
    },
  };
}

/** Withdraw exact assets. `maxWithdraw` is authoritative and clamps the input. */
export function vaultWithdrawIntent(assets: bigint, owner: Address): Intent {
  return {
    label: `Withdraw ${amt(assets)} tUSDC`,
    plan: buildCallPlan({ action: { to: vault, label: "Withdraw from vault" } }),
    reviewed: { minCollateralOut: assets },
    action: {
      address: vault,
      abi: parseAbi([
        "function withdraw(uint256 assets, address receiver, address owner) returns (uint256)",
      ]),
      functionName: "withdraw",
      args: [assets, owner, owner],
    },
    expectedEvent: "Withdraw",
  };
}

/** Repay debt. Payable by any account; the UI always uses the connected wallet. */
export function repayIntent(positionId: bigint, maxAssets: bigint, allowance: bigint): Intent {
  return {
    label: `Repay ${amt(maxAssets)} tUSDC`,
    plan: buildCallPlan({
      action: { to: controller, label: "Repay debt" },
      erc20: {
        token: collateral,
        spender: controller,
        required: maxAssets,
        current: allowance,
        label: `Approve ${amt(maxAssets)} tUSDC`,
      },
    }),
    reviewed: { maxRepayAssets: maxAssets },
    action: {
      address: controller,
      abi: [],
      functionName: "repay",
      args: [positionId, maxAssets],
    },
    expectedEvent: "PositionRepaid",
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [controller, maxAssets],
    },
  };
}

/** Add the exact same outcome id as collateral. Creates no debt. */
export function addCollateralIntent(
  positionId: bigint,
  shares: bigint,
  outcomeId: bigint,
  allowance: bigint,
): Intent {
  return {
    label: `Add ${amt(shares)} shares`,
    plan: buildCallPlan({
      action: { to: controller, label: "Add collateral" },
      erc6909: {
        token: outcomeToken,
        spender: controller,
        outcomeId,
        required: shares,
        current: allowance,
        label: `Approve ${amt(shares)} shares only`,
      },
    }),
    reviewed: {},
    action: {
      address: controller,
      abi: [],
      functionName: "addCollateral",
      args: [positionId, shares],
    },
    expectedEvent: "CollateralAdded",
    approval: {
      address: outcomeToken,
      abi: erc6909Abi as readonly unknown[],
      functionName: "approve",
      args: [controller, outcomeId, shares],
    },
  };
}

/** Withdraw safe excess shares. Needs no approval; the controller custodies them. */
export function withdrawCollateralIntent(positionId: bigint, shares: bigint): Intent {
  return {
    label: `Withdraw ${amt(shares)} shares`,
    plan: buildCallPlan({ action: { to: controller, label: "Withdraw collateral" } }),
    reviewed: {},
    action: {
      address: controller,
      abi: [],
      functionName: "withdrawCollateral",
      args: [positionId, shares],
    },
    expectedEvent: "CollateralWithdrawn",
  };
}

/** Sell shares to reduce debt. The controller already holds the shares. */
export function deleverageIntent(input: {
  positionId: bigint;
  sharesToSell: bigint;
  minCollateralOut: bigint;
  limitPrice: bigint;
  deadlineSeconds: bigint;
  lotSize: bigint;
}): Intent {
  const shares = quantizeDown(input.sharesToSell, input.lotSize);
  return {
    label: `Sell ${amt(shares)} shares`,
    plan: buildCallPlan({ action: { to: controller, label: "Deleverage" } }),
    reviewed: {
      side: "sell",
      minCollateralOut: input.minCollateralOut,
      limitPrice: input.limitPrice,
    },
    action: {
      address: controller,
      abi: [],
      functionName: "deleverage",
      args: [
        {
          positionId: input.positionId,
          sharesToSell: shares,
          minCollateralOut: input.minCollateralOut,
          limitPrice: input.limitPrice,
          orderType: OrderType.Ioc,
          deadline: input.deadlineSeconds,
        },
      ],
    },
    expectedEvent: "PositionDeleveraged",
  };
}

/**
 * Close by repaying and keeping the shares.
 *
 * §11.2 keeps this distinct from selling out: the trader chooses whether to end
 * up holding the outcome or holding collateral.
 */
export function closeToOutcomeIntent(
  positionId: bigint,
  maxRepayAssets: bigint,
  allowance: bigint,
): Intent {
  return {
    label: "Repay and withdraw shares",
    plan: buildCallPlan({
      action: { to: controller, label: "Repay and withdraw" },
      erc20: {
        token: collateral,
        spender: controller,
        required: maxRepayAssets,
        current: allowance,
        label: `Approve ${amt(maxRepayAssets)} tUSDC`,
      },
    }),
    reviewed: { maxRepayAssets },
    action: {
      address: controller,
      abi: [],
      functionName: "close",
      args: [
        {
          positionId,
          maxRepayAssets,
          minCollateralOut: 0n,
          limitPrice: 0n,
          orderType: 0,
          deadline: 0n,
          withdrawOutcome: true,
        },
      ],
    },
    expectedEvent: "PositionClosed",
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [controller, maxRepayAssets],
    },
  };
}

/** Close by selling the outcome into collateral. FOK: the whole size or none. */
export function closeToCollateralIntent(input: {
  positionId: bigint;
  maxRepayAssets: bigint;
  minCollateralOut: bigint;
  limitPrice: bigint;
  deadlineSeconds: bigint;
  allowance: bigint;
}): Intent {
  return {
    label: "Sell shares and close",
    plan: buildCallPlan({
      action: { to: controller, label: "Sell and close" },
      erc20: {
        token: collateral,
        spender: controller,
        required: input.maxRepayAssets,
        current: input.allowance,
        label: `Approve ${amt(input.maxRepayAssets)} tUSDC`,
      },
    }),
    reviewed: {
      side: "sell",
      maxRepayAssets: input.maxRepayAssets,
      minCollateralOut: input.minCollateralOut,
      limitPrice: input.limitPrice,
    },
    action: {
      address: controller,
      abi: [],
      functionName: "close",
      args: [
        {
          positionId: input.positionId,
          maxRepayAssets: input.maxRepayAssets,
          minCollateralOut: input.minCollateralOut,
          limitPrice: input.limitPrice,
          orderType: OrderType.Fok,
          deadline: input.deadlineSeconds,
          withdrawOutcome: false,
        },
      ],
    },
    expectedEvent: "PositionClosed",
    approval: {
      address: collateral,
      abi: erc20Abi,
      functionName: "approve",
      args: [controller, input.maxRepayAssets],
    },
  };
}

/** Settle a resolved position. Permissionless and needs no approval. */
export function settleIntent(positionId: bigint): Intent {
  return {
    label: "Settle position",
    plan: buildCallPlan({ action: { to: controller, label: "Settle position" } }),
    reviewed: {},
    action: { address: controller, abi: [], functionName: "settle", args: [positionId] },
    expectedEvent: "PositionSettled",
  };
}
