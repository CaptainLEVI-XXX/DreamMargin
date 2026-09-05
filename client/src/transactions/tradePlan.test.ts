import { describe, expect, it } from "vitest";
import { decodeFunctionData, encodeFunctionData } from "viem";
import { planTrade } from "./tradePlan";
import { planAcquisition, type BookLevel } from "../domain/bookQuote";
import { SCENARIOS } from "../fixtures/scenarios";

const ONE = 1_000_000n;
const LOT = 1_000n;
const ME = "0x1234567890abcdef1234567890abcdef12345678" as const;
const market = SCENARIOS.healthy.markets[0];
const ASKS: BookLevel[] = [{ yesPrice: 550_000n, quantity: 50_000n * ONE }];

function trade(over: Partial<Parameters<typeof planTrade>[0]> = {}) {
  const quantity = over.quantity ?? 500n * ONE;
  const leverageBps = over.leverageBps ?? 20_000n;
  const side = over.side ?? "yes";
  return planTrade({
    market: { ...market, riskMark: 450_000n, noRiskMark: 450_000n, yesPrice: 500_000n },
    side,
    quantity,
    leverageBps,
    acquisition:
      over.acquisition ??
      planAcquisition({
        side,
        levels: ASKS,
        quantity: leverageBps > 10_000n ? 0n : quantity,
        oneCollateral: ONE,
        lotSize: LOT,
        allowMint: true,
      }),
    levels: over.levels ?? ASKS,
    owned: over.owned ?? 0n,
    collateralAllowance: over.collateralAllowance ?? 0n,
    outcomeAllowance: over.outcomeAllowance ?? 0n,
    account: ME,
    deadlineSeconds: over.deadlineSeconds ?? 1_700_000_000n,
    lotSize: LOT,
    tickSize: LOT,
    ...over,
  });
}

describe("trade planning", () => {
  it("keeps 1x as a normal DreamDEX purchase", () => {
    const sequence = trade({ leverageBps: 10_000n, quantity: 100n * ONE });
    expect(sequence.stage).toBe("spot");
    expect(sequence.intents.map((intent) => intent.label)).toEqual(["Buy 100 YES"]);
    expect(sequence.borrowed).toBe(0n);
  });

  it("opens a leveraged target directly from tUSDC without pre-buying shares", () => {
    const sequence = trade({ owned: 0n });
    expect(sequence.stage).toBe("open");
    expect(sequence.intents).toHaveLength(1);
    expect(sequence.intents[0].action.functionName).toBe("openFromCollateral");
    expect(sequence.financedShares).toBe(500n * ONE);
    expect(sequence.missingShares).toBe(0n);
  });

  it("mirrors the conservative direct-open debt and spend bounds", () => {
    const sequence = trade();
    expect(sequence.maximumCost).toBe(275n * ONE);
    expect(sequence.borrowed).toBe(112_500_000n);
    expect(sequence.estimatedUserCollateral).toBe(162_500_000n);
    expect(sequence.userCollateral).toBe(165_250_000n);
  });

  it("approves only the bounded tUSDC contribution and encodes the new ABI", () => {
    const open = trade().intents[0];
    expect(open.approval?.args).toEqual([expect.anything(), 165_250_000n]);
    const data = encodeFunctionData({
      abi: open.action.abi,
      functionName: open.action.functionName,
      args: open.action.args,
    } as never);
    expect(decodeFunctionData({ abi: open.action.abi, data }).functionName).toBe(
      "openFromCollateral",
    );
  });

  it("needs one confirmation after an existing controller allowance", () => {
    expect(trade({ collateralAllowance: 200n * ONE }).confirmations).toBe(1);
    expect(trade({ collateralAllowance: 0n }).confirmations).toBe(2);
  });

  it("uses the exact NO id, side index, and YES-denominated limit", () => {
    const sequence = trade({
      side: "no",
      levels: [{ yesPrice: 450_000n, quantity: 50_000n * ONE }],
    });
    const params = sequence.intents[0].action.args[0] as {
      outcomeIndex: number;
      key: { outcomeId: bigint };
      limitPrice: bigint;
    };
    expect(params.outcomeIndex).toBe(1);
    expect(params.key.outcomeId).toBe(market.key.outcomeId + 1n);
    expect(params.limitPrice).toBe(450_000n);
  });

  it("uses the independent NO recovery mark and widens stale authorization safely", () => {
    const sequence = trade({
      side: "no",
      market: {
        ...market,
        riskMark: 450_000n,
        noRiskMark: 400_000n,
        yesPrice: 500_000n,
        oracleStale: true,
      },
      levels: [{ yesPrice: 450_000n, quantity: 50_000n * ONE }],
    });
    const params = sequence.intents[0].action.args[0] as {
      maxDebt: bigint;
      maxUserCollateralIn: bigint;
    };

    expect(sequence.borrowed).toBe(100n * ONE);
    expect(sequence.estimatedUserCollateral).toBe(175n * ONE);
    expect(params.maxDebt).toBe(127_500_000n);
    expect(params.maxUserCollateralIn).toBe(202_500_000n);
  });

  it("blocks sizes above either visible depth or the on-chain position ceiling", () => {
    expect(trade({ quantity: 50_001n * ONE }).blocked).toMatch(/maximum position/i);
    expect(
      trade({ quantity: 1_000n * ONE, levels: [{ yesPrice: 550_000n, quantity: 500n * ONE }] })
        .blocked,
    ).toMatch(/cannot fill/i);
  });
});
