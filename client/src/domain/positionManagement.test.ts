import { describe, expect, it } from "vitest";
import { SCENARIOS } from "../fixtures/scenarios";
import { planDebtClearingDeleverage, repaymentLimit } from "./positionManagement";

const UNIT = 1_000_000n;

describe("position management bounds", () => {
  it("buffers a full repayment so debt-index movement cannot strand dust", () => {
    expect(repaymentLimit(3_000_000n)).toBe(3_030_000n);
    expect(repaymentLimit(0n)).toBe(0n);
  });

  it("sells enough executable shares to clear debt instead of leaving minimum-debt dust", () => {
    const template = SCENARIOS.healthy.positions[0];
    const position = {
      ...template,
      shares: 20n * UNIT,
      debtAssets: 3_000_000n,
      market: {
        ...template.market,
        book: {
          yesBids: [{ price: 450_000n, quantity: 50_000n * UNIT }],
          yesAsks: [],
          noBids: [],
          noAsks: [],
        },
      },
    };

    const plan = planDebtClearingDeleverage(position);
    expect(plan).toMatchObject({
      ready: true,
      sharesToSell: 6_734_000n,
      minCollateralOut: 3_000_000n,
      limitPrice: 450_000n,
    });
  });

  it("refuses a deleverage when visible liquidity cannot clear the debt", () => {
    const template = SCENARIOS.healthy.positions[0];
    const plan = planDebtClearingDeleverage({
      ...template,
      market: { ...template.market, book: undefined },
    });
    expect(plan).toMatchObject({ ready: false, reason: expect.stringMatching(/liquidity/i) });
  });
});
