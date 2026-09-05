import { describe, expect, it } from "vitest";
import { DEPLOYMENT, MARKETS } from "./deployment";

describe("DEPLOYMENT", () => {
  it("targets Somnia Shannon", () => {
    expect(DEPLOYMENT.chainId).toBe(50312);
  });

  it("carries the verified controller address", () => {
    expect(DEPLOYMENT.controller).toBe("0xc141ba0c4f7bFAa72628f6Ea28F6e0118F154fe3");
  });

  it("carries the verified vault and oracle", () => {
    expect(DEPLOYMENT.vault).toBe("0x97cE780455c04398c6b4b079Dbb3F434619F8027");
    expect(DEPLOYMENT.oracle).toBe("0x979ADc628D88fb0499F0108C0968433B48b9259C");
  });

  it("keeps deployment numbers and market identities exact", () => {
    expect(DEPLOYMENT.deployedAtBlock).toBe(479866354n);
    expect(typeof DEPLOYMENT.deployedAtBlock).toBe("bigint");
    expect(MARKETS.map((market) => market.symbol)).toEqual(["BTC", "ETH"]);
    expect(MARKETS.every((market) => market.expiry - market.tradingStart > 30n * 86_400n)).toBe(
      true,
    );
  });

  it("uses checksummed addresses", () => {
    for (const key of ["controller", "vault", "oracle", "module", "outcomeToken"] as const) {
      expect(DEPLOYMENT[key]).toMatch(/^0x[0-9a-fA-F]{40}$/);
    }
  });
});
