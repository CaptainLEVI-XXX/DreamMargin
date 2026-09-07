import { describe, expect, it } from "vitest";
import { quotePayFirst } from "./payFirstQuote";

const ONE = 1_000_000n;
const base = {
  side: "yes" as const,
  levels: [{ yesPrice: 550_000n, quantity: 500n * ONE }],
  walletBudget: 50n * ONE,
  maxRiskLeverageBps: 20_000n,
  riskMark: 450_000n,
  oneCollateral: ONE,
  lotSize: 1_000n,
  maximumShares: 500n * ONE,
  authorizationBufferBps: 0n,
};

describe("quotePayFirst", () => {
  it("turns a spot wallet budget into the largest fillable share amount", () => {
    const quote = quotePayFirst({ ...base, targetLeverageBps: 10_000n });

    expect(quote.shares).toBe(90_909_000n);
    expect(quote.walletPayment).toBe(49_999_950n);
    expect(quote.effectiveLeverageBps).toBe(10_000n);
  });

  it("solves a clean cash-on-cash target into the controller risk parameter", () => {
    const quote = quotePayFirst({ ...base, targetLeverageBps: 15_000n });

    expect(quote.shares).toBeGreaterThan(136n * ONE);
    expect(quote.entryCost).toBeLessThan(75_010_000n);
    expect(quote.walletPayment).toBeLessThanOrEqual(50n * ONE);
    expect(quote.effectiveLeverageBps).toBeGreaterThanOrEqual(14_999n);
    expect(quote.effectiveLeverageBps).toBeLessThanOrEqual(15_001n);
    expect(quote.riskLeverageBps).toBeGreaterThan(15_000n);
    expect(quote.riskLeverageBps).toBeLessThan(20_000n);
  });

  it("uses the full risk ceiling only for the maximum choice", () => {
    const quote = quotePayFirst(base);

    expect(quote.riskLeverageBps).toBe(20_000n);
    expect(quote.walletPayment).toBeLessThanOrEqual(50n * ONE);
    expect(quote.effectiveLeverageBps).toBe(16_923n);
  });

  it("treats the entered wallet amount as a hard authorization ceiling", () => {
    const quote = quotePayFirst({ ...base, authorizationBufferBps: 1_000n });

    expect(quote.maximumWalletSpend).toBeLessThanOrEqual(50n * ONE);
    expect(quote.walletPayment).toBeLessThan(50n * ONE);
    expect(quote.effectiveLeverageBps).toBe(16_923n);
  });

  it("quotes NO using the complementary price and its independent mark", () => {
    const quote = quotePayFirst({
      ...base,
      side: "no",
      levels: [{ yesPrice: 450_000n, quantity: 500n * ONE }],
      riskMark: 400_000n,
      targetLeverageBps: 12_500n,
    });

    expect(quote.blocked).toBeUndefined();
    expect(quote.effectiveLeverageBps).toBeGreaterThanOrEqual(12_499n);
    expect(quote.effectiveLeverageBps).toBeLessThanOrEqual(12_501n);
  });

  it("refuses a target beyond the maximum risk-supported leverage", () => {
    const quote = quotePayFirst({ ...base, targetLeverageBps: 17_500n });
    expect(quote.blocked).toMatch(/not available/i);
  });

  it("states when the selected side has no liquidity", () => {
    const quote = quotePayFirst({ ...base, levels: [] });
    expect(quote.blocked).toMatch(/no liquidity/i);
  });
});
