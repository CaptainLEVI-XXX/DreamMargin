import { DEPLOYMENT } from "../config/deployment";

/**
 * The six immutable bindings the integration guide §3 requires the client to
 * validate before it does anything else.
 */
export type BindingReads = {
  controllerVault: string;
  controllerOracle: string;
  controllerModule: string;
  vaultController: string;
  vaultAsset: string;
  oracleConfigurator: string;
};

export type BindingResult = { ok: boolean; mismatches: (keyof BindingReads)[] };

const EXPECTED: Record<keyof BindingReads, string> = {
  controllerVault: DEPLOYMENT.vault,
  controllerOracle: DEPLOYMENT.oracle,
  controllerModule: DEPLOYMENT.module,
  vaultController: DEPLOYMENT.controller,
  vaultAsset: DEPLOYMENT.collateral,
  oracleConfigurator: DEPLOYMENT.controller,
};

/**
 * Startup must refuse to run against a deployment whose wiring disagrees with
 * configuration: a mismatch means the client could display one protocol's state
 * while signing against another. Every mismatch is reported, not just the first,
 * so an operator sees the whole picture in one go.
 */
export function checkBindings(reads: BindingReads): BindingResult {
  const mismatches = (Object.keys(EXPECTED) as (keyof BindingReads)[]).filter(
    (k) => reads[k].toLowerCase() !== EXPECTED[k].toLowerCase(),
  );
  return { ok: mismatches.length === 0, mismatches };
}
