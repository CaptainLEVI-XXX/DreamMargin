import { describe, expect, it, vi } from "vitest";
import { MARKETS } from "../config/deployment";
import { generationKey } from "../domain/marketKey";
import {
  deployedCandidate,
  fetchMarkets,
  leverageEligible,
  toCandidate,
  type IndexedMarket,
} from "./discovery";
import type { GenerationSnapshot } from "./reads";

/** A real indexer row for the live ETH daily market. */
const ETH_ROW: IndexedMarket = {
  marketId: "0x0000000000000000000000000000000000000000000000000000000000011ad6",
  marketAddress: "0xda7e028c9973b3c429b4c093cb984860fc1215f8",
  poolAddress: "0x246a65643ad8b6c6dbd0b017a259da07681242fd",
  nonce: "106",
  yesTokenId: "981762892987552592529876415592559547602498254264742346774773393025536",
  noTokenId: "981762892987552592529876415592559547602498254264742346774773393025537",
  collateral: "0x70a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e",
  question: "ETH closes at or above its opening price",
  asset: "ETH",
  expiry: "1788480000",
  tradingStart: "1788393600",
  clobStatus: "Trading",
  lastPrice: "978000",
  quoteDecimals: 6,
};

describe("toCandidate", () => {
  it("keeps the outcome id exact, which a number would corrupt", () => {
    const c = toCandidate(ETH_ROW);
    expect(c.yesKey.outcomeId).toBe(
      981762892987552592529876415592559547602498254264742346774773393025536n,
    );
    // The same id through a float loses precision entirely.
    expect(Number(ETH_ROW.yesTokenId)).toBeGreaterThan(Number.MAX_SAFE_INTEGER);
  });

  it("derives YES and NO from consecutive token ids", () => {
    const c = toCandidate(ETH_ROW);
    expect(c.noKey.outcomeId).toBe(c.yesKey.outcomeId + 1n);
  });

  it("produces the live ETH YES generation key from indexer data", () => {
    expect(generationKey(toCandidate(ETH_ROW).yesKey)).toBe(
      "0x164dc602b01c94da055e3283c1ec7e5fbd79b2fc240874ad36bc1a11df7543ca",
    );
  });

  it("uses the shared outcome token, not the per-market address", () => {
    // The indexer's marketAddress is the market contract. Using it as the
    // outcome token derives a different generation key entirely.
    const c = toCandidate(ETH_ROW);
    expect(c.yesKey.outcomeToken.toLowerCase()).toBe("0xb52c5934113af5c0bb20eb3c72290c8215f755b9");
    expect(c.yesKey.outcomeToken.toLowerCase()).not.toBe(ETH_ROW.marketAddress.toLowerCase());
  });

  it("converts every numeric field to bigint", () => {
    const c = toCandidate(ETH_ROW);
    for (const v of [c.expiry, c.tradingStart, c.yesKey.marketNonce, c.lastYesPrice]) {
      expect(typeof v).toBe("bigint");
    }
  });

  it("scales one collateral unit from the quote decimals", () => {
    expect(toCandidate(ETH_ROW).oneCollateral).toBe(1_000_000n);
  });

  it("treats a market that has never traded as having no price", () => {
    expect(toCandidate({ ...ETH_ROW, lastPrice: null }).lastYesPrice).toBeNull();
  });

  it("marks a non-trading market as not trading", () => {
    expect(toCandidate({ ...ETH_ROW, clobStatus: "Resolved" }).trading).toBe(false);
  });
});

describe("dedicated markets", () => {
  it("reconstructs the committed generation keys exactly", () => {
    for (const market of MARKETS) {
      const candidate = deployedCandidate(market);
      expect(generationKey(candidate.yesKey)).toBe(market.yesGenerationKey);
      expect(generationKey(candidate.noKey)).toBe(market.noGenerationKey);
    }
  });
});

describe("fetchMarkets", () => {
  it("returns mapped candidates", async () => {
    const fetchImpl = vi.fn(
      async () => new Response(JSON.stringify({ data: { Market: [ETH_ROW] } }), { status: 200 }),
    );
    const markets = await fetchMarkets(
      "https://indexer.test/graphql",
      [ETH_ROW.marketId],
      fetchImpl as never,
    );
    expect(markets).toHaveLength(1);
    expect(markets[0].asset).toBe("ETH");
  });

  it("throws on a transport failure rather than returning an empty list", async () => {
    const fetchImpl = vi.fn(async () => new Response("nope", { status: 502 }));
    await expect(
      fetchMarkets("https://indexer.test/graphql", [], fetchImpl as never),
    ).rejects.toThrow(/502/);
  });

  it("surfaces a GraphQL error instead of silently showing no markets", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(JSON.stringify({ errors: [{ message: "field not found" }] }), { status: 200 }),
    );
    await expect(
      fetchMarkets("https://indexer.test/graphql", [], fetchImpl as never),
    ).rejects.toThrow(/field not found/);
  });

  it("returns an empty list when the indexer knows no such market", async () => {
    const fetchImpl = vi.fn(
      async () => new Response(JSON.stringify({ data: { Market: [] } }), { status: 200 }),
    );
    expect(await fetchMarkets("https://indexer.test/graphql", [], fetchImpl as never)).toEqual([]);
  });
});

describe("leverageEligible", () => {
  const candidate = toCandidate(ETH_ROW);
  const ok: GenerationSnapshot = {
    registered: true,
    enabled: true,
    frozen: false,
    keyMatches: true,
    maintenanceLtvBps: 6_000n,
    headroomCaps: { position: 100_000_000n, outcome: 300_000_000n, market: 500_000_000n },
  };

  it("allows a registered, enabled, matching generation on a trading market", () => {
    expect(leverageEligible(ok, candidate)).toBe(true);
  });

  it("refuses an unregistered generation", () => {
    expect(leverageEligible({ ...ok, registered: false }, candidate)).toBe(false);
  });

  it("refuses a frozen generation", () => {
    expect(leverageEligible({ ...ok, frozen: true }, candidate)).toBe(false);
  });

  it("refuses a disabled generation", () => {
    expect(leverageEligible({ ...ok, enabled: false }, candidate)).toBe(false);
  });

  it("refuses when the on-chain key does not match, as with a recycled pool", () => {
    expect(leverageEligible({ ...ok, keyMatches: false }, candidate)).toBe(false);
  });

  it("refuses once the market stops trading", () => {
    expect(leverageEligible(ok, { ...candidate, trading: false })).toBe(false);
  });
});
