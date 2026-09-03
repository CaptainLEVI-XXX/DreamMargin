import { describe, expect, it } from "vitest";
import { DEPLOYMENT } from "./deployment";

describe("DEPLOYMENT", () => {
  it("targets Somnia Shannon", () => {
    expect(DEPLOYMENT.chainId).toBe(50312);
  });

  it("carries the verified controller address", () => {
    expect(DEPLOYMENT.controller).toBe("0x50B054bD4A891C44A66c86e8c82A45AE0630869c");
  });

  it("carries the verified vault and oracle", () => {
    expect(DEPLOYMENT.vault).toBe("0xE4B62C03b4a618f5713C6f0b06F6bB763e7685a6");
    expect(DEPLOYMENT.oracle).toBe("0x278aDFBF3D6906fb17616cFA35a3c11A3dDA93d1");
  });

  it("keeps the deploy block as bigint for log scanning", () => {
    expect(DEPLOYMENT.deployedAtBlock).toBe(478284318n);
    expect(typeof DEPLOYMENT.deployedAtBlock).toBe("bigint");
  });

  it("uses checksummed addresses", () => {
    for (const key of ["controller", "vault", "oracle", "module", "outcomeToken"] as const) {
      expect(DEPLOYMENT[key]).toMatch(/^0x[0-9a-fA-F]{40}$/);
    }
  });
});
