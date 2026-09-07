import { describe, expect, it } from "vitest";
import { generationKey, marketKeysEqual } from "./marketKey";
import type { MarketKey } from "./models";

/** The live ETH YES generation, read from the Shannon deployment. */
const ETH_YES: MarketKey = {
  marketId: "0x0000000000000000000000000000000000000000000000000000000000011ad6",
  pool: "0x246a65643ad8b6c6dbd0b017a259da07681242fd",
  marketNonce: 106n,
  outcomeToken: "0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9",
  outcomeId: 981762892987552592529876415592559547602498254264742346774773393025536n,
  collateral: "0x70a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e",
};

describe("generationKey", () => {
  it("reproduces the live ETH YES generation key", () => {
    expect(generationKey(ETH_YES)).toBe(
      "0x164dc602b01c94da055e3283c1ec7e5fbd79b2fc240874ad36bc1a11df7543ca",
    );
  });

  it("is insensitive to address casing", () => {
    const upper = {
      ...ETH_YES,
      pool: `0x${ETH_YES.pool.slice(2).toUpperCase()}`,
    } as MarketKey;
    expect(generationKey(upper)).toBe(generationKey(ETH_YES));
  });

  it("changes when the pool nonce changes, so a recycled pool cannot collide", () => {
    expect(generationKey({ ...ETH_YES, marketNonce: 107n })).not.toBe(generationKey(ETH_YES));
  });

  it("changes when the outcome id changes", () => {
    expect(generationKey({ ...ETH_YES, outcomeId: ETH_YES.outcomeId + 1n })).not.toBe(
      generationKey(ETH_YES),
    );
  });

  it("changes when the collateral changes", () => {
    expect(
      generationKey({ ...ETH_YES, collateral: "0x0000000000000000000000000000000000000001" }),
    ).not.toBe(generationKey(ETH_YES));
  });
});

describe("marketKeysEqual", () => {
  it("accepts an identical key", () => {
    expect(marketKeysEqual(ETH_YES, { ...ETH_YES })).toBe(true);
  });

  it("compares addresses case-insensitively", () => {
    const upper = {
      ...ETH_YES,
      pool: `0x${ETH_YES.pool.slice(2).toUpperCase()}`,
    } as MarketKey;
    expect(marketKeysEqual(ETH_YES, upper)).toBe(true);
  });

  it("rejects a different nonce", () => {
    expect(marketKeysEqual(ETH_YES, { ...ETH_YES, marketNonce: 107n })).toBe(false);
  });

  it("rejects a different collateral", () => {
    expect(
      marketKeysEqual(ETH_YES, {
        ...ETH_YES,
        collateral: "0x0000000000000000000000000000000000000001",
      }),
    ).toBe(false);
  });

  it("rejects a different outcome id", () => {
    expect(marketKeysEqual(ETH_YES, { ...ETH_YES, outcomeId: 1n })).toBe(false);
  });
});
