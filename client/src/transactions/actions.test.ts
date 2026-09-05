import { describe, expect, it } from "vitest";
import { controllerAbi } from "../web3/abis/controllerAbi";
import { vaultAbi } from "../web3/abis/vaultAbi";
import { DEPLOYMENT } from "../config/deployment";
import {
  addCollateralIntent,
  buyOutcomeIntent,
  closeToCollateralIntent,
  closeToOutcomeIntent,
  deleverageIntent,
  faucetIntent,
  mintSetIntent,
  observeIntent,
  repayIntent,
  settleIntent,
  vaultDepositIntent,
  vaultWithdrawIntent,
  withdrawCollateralIntent,
  OrderKind,
  OrderType,
} from "./actions";

const POOL = "0x246a65643ad8b6c6dbd0b017a259da07681242fd" as const;
const ME = "0x1234567890abcdef1234567890abcdef12345678" as const;
const USDC = 1_000_000n;
const YES_ID = 981762892987552592529876415592559547602498254264742346774773393025536n;

const controllerEvents = controllerAbi.filter((e) => e.type === "event").map((e) => e.name);
const vaultEvents = vaultAbi.filter((e) => e.type === "event").map((e) => e.name);

describe("expected events exist on-chain", () => {
  // A wrong name means verifyEvent can never succeed and nothing would ever be
  // reported as done, so these are pinned against the generated ABIs.
  it("names real controller events", () => {
    const intents = [
      repayIntent(1n, USDC, 0n),
      addCollateralIntent(1n, USDC, YES_ID, 0n),
      withdrawCollateralIntent(1n, USDC),
      deleverageIntent({
        positionId: 1n,
        sharesToSell: USDC,
        minCollateralOut: 1n,
        limitPrice: 1n,
        deadlineSeconds: 1n,
        lotSize: 1000n,
      }),
      closeToOutcomeIntent(1n, USDC, 0n),
      closeToCollateralIntent({
        positionId: 1n,
        maxRepayAssets: USDC,
        minCollateralOut: 1n,
        limitPrice: 1n,
        deadlineSeconds: 1n,
        allowance: 0n,
      }),
      settleIntent(1n),
    ];
    for (const intent of intents) {
      expect(controllerEvents, intent.label).toContain(intent.expectedEvent);
    }
  });

  it("names real vault events", () => {
    expect(vaultEvents).toContain(vaultDepositIntent(USDC, ME, 0n).expectedEvent);
    expect(vaultEvents).toContain(vaultWithdrawIntent(USDC, ME).expectedEvent);
  });
});

describe("faucet", () => {
  it("needs no approval", () => {
    expect(faucetIntent(100n * USDC).plan.calls).toHaveLength(1);
  });

  it("targets the collateral token", () => {
    expect(faucetIntent(100n * USDC).action.address).toBe(DEPLOYMENT.collateral);
  });
});

describe("oracle refresh", () => {
  it("is one permissionless write to the deployed oracle", () => {
    const key = `0x${"11".repeat(32)}` as const;
    const intent = observeIntent(key);
    expect(intent.action.address).toBe(DEPLOYMENT.oracle);
    expect(intent.action.args).toEqual([key]);
    expect(intent.plan.calls).toHaveLength(1);
  });
});

describe("mintSet", () => {
  it("mints both outcomes to the same wallet", () => {
    const intent = mintSetIntent(POOL, 100n * USDC, ME);
    expect(intent.action.args).toEqual([ME, ME, 100n * USDC]);
  });

  it("approves the pool for exactly the collateral spent", () => {
    const intent = mintSetIntent(POOL, 100n * USDC, ME);
    expect(intent.approval?.args).toEqual([POOL, 100n * USDC]);
    expect(intent.reviewed.maxCollateralIn).toBe(100n * USDC);
  });
});

describe("buyOutcome", () => {
  const base = {
    pool: POOL,
    quantity: 10n * USDC,
    oneCollateral: USDC,
    tickSize: 1_000n,
    lotSize: 1_000n,
    deadlineSeconds: 1_700_000_000n,
    collateralAllowance: 0n,
  };

  it("buys YES with the YES order kind", () => {
    const intent = buyOutcomeIntent({ ...base, side: "yes", maxPrice: 985_000n });
    expect(intent.action.args[0]).toBe(OrderKind.BuyYes);
  });

  it("buys NO with the NO order kind", () => {
    const intent = buyOutcomeIntent({ ...base, side: "no", maxPrice: 20_000n });
    expect(intent.action.args[0]).toBe(OrderKind.BuyNo);
  });

  it("expresses a NO ceiling as a YES-price threshold", () => {
    // Paying at most 2c for NO means the YES price must be at least 98c.
    const intent = buyOutcomeIntent({ ...base, side: "no", maxPrice: 20_000n });
    expect(intent.action.args[1]).toBe(980_000n);
  });

  it("rounds quantity down to the lot so the venue cannot reject it", () => {
    const intent = buyOutcomeIntent({
      ...base,
      side: "yes",
      maxPrice: 985_000n,
      quantity: 10_500n,
    });
    expect(intent.action.args[2]).toBe(10_000n);
  });

  it("uses an immediate order, never a resting one", () => {
    const intent = buyOutcomeIntent({ ...base, side: "yes", maxPrice: 985_000n });
    expect(intent.action.args[4]).toBe(OrderType.Ioc);
  });

  it("converts the deadline to nanoseconds", () => {
    const intent = buyOutcomeIntent({ ...base, side: "yes", maxPrice: 985_000n });
    expect(intent.action.args[3]).toBe(1_700_000_000n * 1_000_000_000n);
  });

  it("reviews a maximum spend derived from the quantity and limit", () => {
    const intent = buyOutcomeIntent({ ...base, side: "yes", maxPrice: 985_000n });
    expect(intent.reviewed.maxCollateralIn).toBe(9_850_000n);
    expect(intent.reviewed.side).toBe("buy");
  });

  it("skips the approval when allowance already covers the spend", () => {
    const intent = buyOutcomeIntent({
      ...base,
      side: "yes",
      maxPrice: 985_000n,
      collateralAllowance: 1_000n * USDC,
    });
    expect(intent.plan.calls).toHaveLength(1);
  });
});

describe("position lifecycle bounds", () => {
  it("reviews repayment as a maximum, not a minimum", () => {
    expect(repayIntent(1n, 50n * USDC, 0n).reviewed.maxRepayAssets).toBe(50n * USDC);
  });

  it("approves the controller for exactly the repayment maximum", () => {
    expect(repayIntent(1n, 50n * USDC, 0n).approval?.args).toEqual([
      DEPLOYMENT.controller,
      50n * USDC,
    ]);
  });

  it("adds collateral with an exact-id approval, not an operator grant", () => {
    const intent = addCollateralIntent(1n, 10n * USDC, YES_ID, 0n);
    expect(intent.approval?.args).toEqual([DEPLOYMENT.controller, YES_ID, 10n * USDC]);
  });

  it("needs no approval to withdraw collateral the controller already holds", () => {
    expect(withdrawCollateralIntent(1n, USDC).plan.calls).toHaveLength(1);
    expect(withdrawCollateralIntent(1n, USDC).approval).toBeUndefined();
  });

  it("needs no approval to deleverage", () => {
    const intent = deleverageIntent({
      positionId: 1n,
      sharesToSell: 10n * USDC,
      minCollateralOut: 5n * USDC,
      limitPrice: 900_000n,
      deadlineSeconds: 1n,
      lotSize: 1_000n,
    });
    expect(intent.plan.calls).toHaveLength(1);
    expect(intent.reviewed.side).toBe("sell");
  });

  it("closes to outcome without a sale, so it sets no price bound", () => {
    const intent = closeToOutcomeIntent(1n, 100n * USDC, 0n);
    const params = intent.action.args[0] as { withdrawOutcome: boolean; limitPrice: bigint };
    expect(params.withdrawOutcome).toBe(true);
    expect(params.limitPrice).toBe(0n);
  });

  it("closes to collateral with a fill-or-kill sale of the whole position", () => {
    const intent = closeToCollateralIntent({
      positionId: 1n,
      maxRepayAssets: 100n * USDC,
      minCollateralOut: 90n * USDC,
      limitPrice: 900_000n,
      deadlineSeconds: 1n,
      allowance: 0n,
    });
    const params = intent.action.args[0] as { withdrawOutcome: boolean; orderType: number };
    expect(params.withdrawOutcome).toBe(false);
    expect(params.orderType).toBe(OrderType.Fok);
  });

  it("settles without approval or bounds", () => {
    const intent = settleIntent(1n);
    expect(intent.plan.calls).toHaveLength(1);
    expect(intent.reviewed).toEqual({});
  });
});

describe("vault", () => {
  it("approves exactly the deposit", () => {
    expect(vaultDepositIntent(500n * USDC, ME, 0n).approval?.args).toEqual([
      DEPLOYMENT.vault,
      500n * USDC,
    ]);
  });

  it("skips approval when allowance suffices", () => {
    expect(vaultDepositIntent(500n * USDC, ME, 500n * USDC).plan.calls).toHaveLength(1);
  });

  it("needs no approval to withdraw own shares", () => {
    expect(vaultWithdrawIntent(100n * USDC, ME).plan.calls).toHaveLength(1);
  });

  it("reviews a withdrawal as a minimum received", () => {
    expect(vaultWithdrawIntent(100n * USDC, ME).reviewed.minCollateralOut).toBe(100n * USDC);
  });
});
