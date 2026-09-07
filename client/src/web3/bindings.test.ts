import { describe, expect, it } from "vitest";
import { DEPLOYMENT } from "../config/deployment";
import { checkBindings, type BindingReads } from "./bindings";

const good: BindingReads = {
  controllerVault: DEPLOYMENT.vault,
  controllerOracle: DEPLOYMENT.oracle,
  controllerModule: DEPLOYMENT.module,
  vaultController: DEPLOYMENT.controller,
  vaultAsset: DEPLOYMENT.collateral,
  oracleConfigurator: DEPLOYMENT.controller,
};

describe("checkBindings", () => {
  it("accepts a matching deployment", () => {
    expect(checkBindings(good).ok).toBe(true);
  });

  it("tolerates address casing differences", () => {
    expect(checkBindings({ ...good, controllerVault: DEPLOYMENT.vault.toLowerCase() }).ok).toBe(
      true,
    );
  });

  it("rejects a mismatched vault and names the field", () => {
    const r = checkBindings({
      ...good,
      controllerVault: "0x0000000000000000000000000000000000000001",
    });
    expect(r.ok).toBe(false);
    expect(r.mismatches).toContain("controllerVault");
  });

  it("reports every mismatch, not only the first", () => {
    const wrong = "0x0000000000000000000000000000000000000001";
    const r = checkBindings({ ...good, controllerVault: wrong, vaultAsset: wrong });
    expect(r.mismatches).toHaveLength(2);
  });

  it("rejects an oracle configured by something other than the controller", () => {
    const r = checkBindings({
      ...good,
      oracleConfigurator: "0x0000000000000000000000000000000000000002",
    });
    expect(r.ok).toBe(false);
    expect(r.mismatches).toContain("oracleConfigurator");
  });

  it("rejects a vault whose asset is not the configured collateral", () => {
    const r = checkBindings({
      ...good,
      vaultAsset: "0x0000000000000000000000000000000000000003",
    });
    expect(r.mismatches).toEqual(["vaultAsset"]);
  });
});
