import { describe, expect, it } from "vitest";
import { planTrade } from "./tradePlan";
import { planAcquisition, type BookLevel } from "../domain/bookQuote";
import { SCENARIOS } from "../fixtures/scenarios";

const ONE = 1_000_000n;
const LOT = 1_000n;
const ME = "0x1234567890abcdef1234567890abcdef12345678" as const;
const market = SCENARIOS.healthy.markets[0];
const ASKS: BookLevel[] = [
  { yesPrice: 983_000n, quantity: 1_000_000n },
  { yesPrice: 985_000n, quantity: 5_000_000n },
];

function trade(over: Partial<Parameters<typeof planTrade>[0]> = {}) {
  const quantity = over.quantity ?? 2n * ONE;
  const owned = over.owned ?? 0n;
  const acquisition =
    over.acquisition ??
    planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: quantity > owned ? quantity - owned : 0n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
  return planTrade({
    market,
    side: "yes",
    quantity,
    leverageBps: 10_000n,
    acquisition,
    owned,
    collateralAllowance: 0n,
    outcomeAllowance: 0n,
    account: ME,
    deadlineSeconds: 1_700_000_000n,
    lotSize: LOT,
    tickSize: LOT,
    ...over,
  });
}

describe("1x is a purchase and nothing more", () => {
  it("plans only the buy", () => {
    const seq = trade({ leverageBps: 10_000n });
    expect(seq.intents.map((i) => i.label)).toEqual(["Buy 2 YES"]);
    expect(seq.borrowed).toBe(0n);
  });

  it("needs approval plus order, so two confirmations", () => {
    expect(trade({ leverageBps: 10_000n }).confirmations).toBe(2);
  });

  it("drops to one confirmation when collateral is already approved", () => {
    expect(trade({ leverageBps: 10_000n, collateralAllowance: 100n * ONE }).confirmations).toBe(1);
  });
});

describe("above 1x adds the position open", () => {
  it("buys first, then opens", () => {
    const seq = trade({ leverageBps: 15_000n });
    expect(seq.intents.map((i) => i.label)).toEqual(["Buy 2 YES", "Open 1.5x position"]);
  });

  it("borrows against the shares that will be held", () => {
    const seq = trade({ leverageBps: 15_000n });
    expect(seq.borrowed).toBeGreaterThan(0n);
    expect(seq.committed).toBe(2n * ONE);
  });

  it("counts every confirmation across both intents", () => {
    // approve collateral, buy, approve outcome id, open
    expect(trade({ leverageBps: 15_000n }).confirmations).toBe(4);
  });

  it("reviews the borrow as a maximum and the fill as a minimum", () => {
    const open = trade({ leverageBps: 15_000n }).intents[1];
    expect(open.reviewed.maxCollateralIn).toBe(trade({ leverageBps: 15_000n }).borrowed);
    expect(open.reviewed.minSharesOut).toBeGreaterThan(0n);
  });

  it("approves the exact outcome id for exactly the committed shares", () => {
    const open = trade({ leverageBps: 15_000n }).intents[1];
    expect(open.approval?.args).toEqual([expect.anything(), market.key.outcomeId, 2n * ONE]);
  });
});

describe("shares already held", () => {
  it("skips the purchase entirely when the wallet already holds enough", () => {
    const seq = trade({ quantity: 2n * ONE, owned: 5n * ONE, leverageBps: 15_000n });
    expect(seq.intents.map((i) => i.label)).toEqual(["Open 1.5x position"]);
  });

  it("commits everything held rather than only the requested size", () => {
    const seq = trade({ quantity: 2n * ONE, owned: 5n * ONE, leverageBps: 15_000n });
    expect(seq.committed).toBe(5n * ONE);
  });

  it("buys only the shortfall", () => {
    const seq = trade({ quantity: 3n * ONE, owned: 1n * ONE, leverageBps: 10_000n });
    expect(seq.intents[0].label).toBe("Buy 2 YES");
  });
});

describe("book depth and minting", () => {
  it("adds a mint leg when the book cannot cover the size", () => {
    const seq = trade({ quantity: 10n * ONE, leverageBps: 10_000n });
    const labels = seq.intents.map((i) => i.label);
    expect(labels[0]).toMatch(/^Buy 6 YES$/);
    expect(labels[1]).toMatch(/complete sets/i);
  });

  it("blocks with a reason when nothing can be acquired", () => {
    const seq = trade({
      quantity: 5n * ONE,
      acquisition: planAcquisition({
        side: "yes",
        levels: [],
        quantity: 5n * ONE,
        oneCollateral: ONE,
        lotSize: LOT,
        allowMint: false,
      }),
    });
    expect(seq.intents).toHaveLength(0);
    expect(seq.blocked).toMatch(/no liquidity/i);
  });
});

describe("side selection", () => {
  it("opens against the NO outcome index when buying NO", () => {
    const seq = planTrade({
      market,
      side: "no",
      quantity: 1n * ONE,
      leverageBps: 15_000n,
      acquisition: {
        fromBook: 1n * ONE,
        fromMint: 0n,
        bookCost: 20_000n,
        mintCost: 0n,
        limitYesPrice: 980_000n,
      },
      owned: 0n,
      collateralAllowance: 0n,
      outcomeAllowance: 0n,
      account: ME,
      deadlineSeconds: 1n,
      lotSize: LOT,
      tickSize: LOT,
    });
    const open = seq.intents.at(-1);
    const params = open?.action.args[0] as { outcomeIndex: number };
    expect(params.outcomeIndex).toBe(1);
  });
});
