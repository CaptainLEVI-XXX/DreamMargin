import { describe, expect, it } from "vitest";
import { controllerAbi } from "./controllerAbi";
import { errorsAbi } from "./errorsAbi";
import { oracleAbi } from "./oracleAbi";
import { vaultAbi } from "./vaultAbi";

function names(abi: readonly { type: string; name?: string }[]): string[] {
  return abi.filter((e) => e.type === "function").map((e) => e.name as string);
}

describe("generated ABIs", () => {
  it("exposes every trader lifecycle write on the controller", () => {
    const fns = names(controllerAbi);
    for (const fn of [
      "openPosition",
      "repay",
      "addCollateral",
      "withdrawCollateral",
      "deleverage",
      "close",
      "settle",
    ]) {
      expect(fns).toContain(fn);
    }
  });

  it("exposes the controller reads the client needs", () => {
    const fns = names(controllerAbi);
    for (const fn of ["getPosition", "getGeneration", "protocolMode", "globalRiskConfig"]) {
      expect(fns).toContain(fn);
    }
  });

  it("exposes the binding reads used at startup", () => {
    expect(names(controllerAbi)).toEqual(expect.arrayContaining(["vault", "oracle", "module"]));
    expect(names(vaultAbi)).toEqual(expect.arrayContaining(["asset", "controller"]));
    expect(names(oracleAbi)).toContain("configurator");
  });

  it("exposes the ERC-4626 surface on the vault", () => {
    const fns = names(vaultAbi);
    for (const fn of [
      "totalAssets",
      "availableLiquidity",
      "maxWithdraw",
      "maxRedeem",
      "previewDeposit",
    ]) {
      expect(fns).toContain(fn);
    }
  });

  it("declares the custom errors, which the interfaces do not carry", () => {
    const errors = errorsAbi.filter((e) => e.type === "error").map((e) => e.name as string);
    expect(errors.length).toBeGreaterThan(50);
    // Without these a revert cannot be decoded and §15's specific copy is lost.
    for (const name of [
      "StaleOracle",
      "PoolRecycled",
      "DebtCapExceeded",
      "InsufficientHealth",
      "InsufficientBookDepth",
      "OpeningCutoffReached",
      "UtilizationExceeded",
      "SettlementNotFinal",
    ]) {
      expect(errors).toContain(name);
    }
  });

  it("confirms the interface ABIs carry no errors of their own", () => {
    // The compiler already proves this: because the generated ABIs are `as
    // const`, each entry's `type` narrows to "function" | "event", so an
    // "error" entry is unrepresentable. These assignments fail to compile if a
    // future artifact ever adds one — which is why errorsAbi is generated
    // separately from the library.
    type ControllerEntry = (typeof controllerAbi)[number]["type"];
    type VaultEntry = (typeof vaultAbi)[number]["type"];
    type OracleEntry = (typeof oracleAbi)[number]["type"];

    const controllerHasNoErrors: Extract<ControllerEntry, "error"> extends never ? true : false =
      true;
    const vaultHasNoErrors: Extract<VaultEntry, "error"> extends never ? true : false = true;
    const oracleHasNoErrors: Extract<OracleEntry, "error"> extends never ? true : false = true;

    expect([controllerHasNoErrors, vaultHasNoErrors, oracleHasNoErrors]).toEqual([
      true,
      true,
      true,
    ]);
  });

  it("exposes the oracle risk reads", () => {
    const fns = names(oracleAbi);
    for (const fn of ["conservativeTwap", "generationState", "observationAt"]) {
      expect(fns).toContain(fn);
    }
  });
});
