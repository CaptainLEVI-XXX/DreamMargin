import { describe, expect, it } from "vitest";
import { planAcquisition, quoteBuy, quoteSell, type BookLevel } from "./bookQuote";

const ONE = 1_000_000n;
const LOT = 1_000n;

/** The live ETH ask side, read from the pool. */
const ASKS: BookLevel[] = [
  { yesPrice: 983_000n, quantity: 1_000_000n },
  { yesPrice: 985_000n, quantity: 5_000_000n },
];

/** The live YES bid side, which a NO buy consumes. */
const BIDS: BookLevel[] = [
  { yesPrice: 981_000n, quantity: 1_000_000n },
  { yesPrice: 980_000n, quantity: 200_000_000n },
];

describe("quoteBuy for YES", () => {
  it("fills entirely at the best level when it is deep enough", () => {
    const q = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 500_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.fillable).toBe(500_000n);
    expect(q.shortfall).toBe(0n);
    expect(q.limitYesPrice).toBe(983_000n);
  });

  it("walks into the next level and reports the worst price touched", () => {
    const q = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 3_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.fillable).toBe(3_000_000n);
    expect(q.limitYesPrice).toBe(985_000n);
  });

  it("reports a shortfall rather than pretending the book is deeper", () => {
    const q = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 10_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.fillable).toBe(6_000_000n);
    expect(q.shortfall).toBe(4_000_000n);
  });

  it("costs roughly the market price, not the full unit", () => {
    const q = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.cost).toBe(983_000n);
    expect(q.averagePrice).toBe(983_000n);
  });

  it("rounds cost up so the wallet is never short", () => {
    const odd: BookLevel[] = [{ yesPrice: 333_333n, quantity: ONE }];
    const q = quoteBuy({
      side: "yes",
      levels: odd,
      quantity: 1_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.cost).toBe(334n);
  });

  it("quantizes the request down to the lot", () => {
    const q = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 1_500n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.fillable).toBe(1_000n);
  });

  it("fills nothing against an empty book", () => {
    const q = quoteBuy({
      side: "yes",
      levels: [],
      quantity: ONE,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.fillable).toBe(0n);
    expect(q.shortfall).toBe(ONE);
    expect(q.cost).toBe(0n);
  });
});

describe("quoteBuy for NO", () => {
  it("prices NO as the complement of the YES bid", () => {
    // Buying NO against a 98.1c YES bid costs 1.9c.
    const q = quoteBuy({
      side: "no",
      levels: BIDS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.cost).toBe(19_000n);
    expect(q.averagePrice).toBe(19_000n);
  });

  it("still reports the limit in the YES convention", () => {
    const q = quoteBuy({
      side: "no",
      levels: BIDS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.limitYesPrice).toBe(981_000n);
  });

  it("is far cheaper than YES on this book, as the prices imply", () => {
    const yes = quoteBuy({
      side: "yes",
      levels: ASKS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    const no = quoteBuy({
      side: "no",
      levels: BIDS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(no.cost).toBeLessThan(yes.cost);
  });
});

describe("quoteSell", () => {
  it("values an immediate YES exit against bids, not the midpoint", () => {
    const q = quoteSell({
      side: "yes",
      levels: [{ yesPrice: 450_000n, quantity: 200n * ONE }],
      quantity: 100n * ONE,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.proceeds).toBe(45n * ONE);
    expect(q.averagePrice).toBe(450_000n);
  });

  it("values a NO exit as the complement of the YES ask", () => {
    const q = quoteSell({
      side: "no",
      levels: [{ yesPrice: 550_000n, quantity: 200n * ONE }],
      quantity: 100n * ONE,
      oneCollateral: ONE,
      lotSize: LOT,
    });
    expect(q.proceeds).toBe(45n * ONE);
    expect(q.averagePrice).toBe(450_000n);
  });
});

describe("planAcquisition", () => {
  it("uses the book alone when it can cover the size", () => {
    const plan = planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: 2_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
    expect(plan.fromMint).toBe(0n);
    expect(plan.note).toBeUndefined();
  });

  it("mints only the part the book cannot cover", () => {
    const plan = planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: 10_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
    expect(plan.fromBook).toBe(6_000_000n);
    expect(plan.fromMint).toBe(4_000_000n);
  });

  it("says minting costs the full unit and returns the other outcome", () => {
    const plan = planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: 10_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
    expect(plan.note).toMatch(/full unit price/i);
    expect(plan.note).toMatch(/NO shares/);
    // Formatted, never native units: "6 of 10", not "6000000 of 10000000".
    expect(plan.note).toMatch(/6 of 10\b/);
    expect(plan.note).not.toMatch(/000000/);
  });

  it("names the opposite outcome correctly for a NO buy", () => {
    const plan = planAcquisition({
      side: "no",
      levels: [],
      quantity: ONE,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
    expect(plan.note).toMatch(/YES shares/);
  });

  it("leaves a shortfall unfilled when minting is refused", () => {
    const plan = planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: 10_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: false,
    });
    expect(plan.fromBook).toBe(6_000_000n);
    expect(plan.fromMint).toBe(0n);
  });

  it("prefers the book because it is genuinely cheaper", () => {
    const plan = planAcquisition({
      side: "yes",
      levels: ASKS,
      quantity: 1_000_000n,
      oneCollateral: ONE,
      lotSize: LOT,
      allowMint: true,
    });
    // 98.3c on the book against 100c to mint.
    expect(plan.bookCost).toBeLessThan(1_000_000n);
  });
});
