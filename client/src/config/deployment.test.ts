import { describe, expect, it } from "vitest";
import { DEPLOYMENT, MARKETS } from "./deployment";

describe("DEPLOYMENT", () => {
  it("targets Somnia Shannon", () => {
    expect(DEPLOYMENT.chainId).toBe(50312);
  });

  it("carries the verified controller address", () => {
    expect(DEPLOYMENT.controller).toBe("0x7237B9E2EE4247c911A8710e9325dB52Fc57Ef1B");
  });

  it("carries the verified vault and oracle", () => {
    expect(DEPLOYMENT.vault).toBe("0xBe415FEB724999B6c99790c681B1297309C629E4");
    expect(DEPLOYMENT.oracle).toBe("0x9Dc09C580C8b5E1cc3Ba96135a99d50b2c0406e9");
  });

  it("keeps deployment numbers and market identities exact", () => {
    expect(DEPLOYMENT.deployedAtBlock).toBe(480025555n);
    expect(typeof DEPLOYMENT.deployedAtBlock).toBe("bigint");
    expect(MARKETS.map((market) => market.symbol)).toEqual(["BTC", "ETH"]);
    expect(MARKETS.every((market) => market.expiry - market.tradingStart > 30n * 86_400n)).toBe(
      true,
    );
  });

  it("publishes the live share-depth envelope", () => {
    expect(DEPLOYMENT.maximumPositionShares).toBe(20_000_000_000n);
    expect(DEPLOYMENT.certifiedDepthShares).toBe(25_000_000_000n);
    expect(DEPLOYMENT.seededBookShares).toBe(50_000_000_000n);
  });

  it("uses checksummed addresses", () => {
    for (const key of ["controller", "vault", "oracle", "module", "outcomeToken"] as const) {
      expect(DEPLOYMENT[key]).toMatch(/^0x[0-9a-fA-F]{40}$/);
    }
  });
});
