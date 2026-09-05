import { describe, expect, it } from "vitest";
import { errorsAbi } from "../web3/abis/errorsAbi";
import { describeContractError, mappedErrorNames } from "./errors";

const CONTRACT_ERRORS = errorsAbi.filter((e) => e.type === "error").map((e) => e.name as string);
const INTEGRATION_ERRORS = ["InsufficientBalance"];

describe("describeContractError", () => {
  it("maps a stale oracle to recovery that keeps repay available", () => {
    const r = describeContractError("StaleOracle");
    expect(r.message).toMatch(/stale/i);
    expect(r.recovery).toMatch(/repay|add collateral/i);
  });

  it("maps insufficient book depth to reducing size", () => {
    expect(describeContractError("InsufficientBookDepth").recovery).toMatch(/reduce/i);
  });

  it("maps a recycled pool to refreshing markets", () => {
    expect(describeContractError("PoolRecycled").message).toMatch(/generation/i);
  });

  it("maps debt cap exceeded to a credit limit", () => {
    expect(describeContractError("DebtCapExceeded").message).toMatch(/credit limit/i);
  });

  it("gives every documented error non-empty message and recovery copy", () => {
    for (const name of [
      "ActionBlocked",
      "UnsupportedGeneration",
      "GenerationFrozen",
      "PoolRecycled",
      "InvalidMarketStatus",
      "OracleNotReady",
      "StaleOracle",
      "OpeningCutoffReached",
      "InvalidTick",
      "InvalidLot",
      "InsufficientBookDepth",
      "InsufficientSharesOut",
      "DebtCapExceeded",
      "UtilizationExceeded",
      "InsufficientHealth",
      "RepaymentLimitExceeded",
      "IncompleteClose",
      "InsufficientLiquidity",
      "SettlementNotFinal",
    ]) {
      const r = describeContractError(name);
      expect(r.known, `${name} should be mapped`).toBe(true);
      expect(r.message.length).toBeGreaterThan(0);
      expect(r.recovery.length).toBeGreaterThan(0);
    }
  });

  it("keeps the raw name for an unknown error instead of hiding it", () => {
    const r = describeContractError("SomeNewError");
    expect(r.known).toBe(false);
    expect(r.raw).toBe("SomeNewError");
    expect(r.message).toContain("SomeNewError");
    expect(r.message).not.toMatch(/something went wrong/i);
  });

  it("never produces generic copy for a mapped error", () => {
    for (const name of mappedErrorNames()) {
      expect(describeContractError(name).message).not.toMatch(/something went wrong/i);
    }
  });
});

describe("mapping stays in step with the contracts", () => {
  it("maps only errors the contracts actually declare", () => {
    const unknown = mappedErrorNames().filter(
      (n) => !CONTRACT_ERRORS.includes(n) && !INTEGRATION_ERRORS.includes(n),
    );
    expect(unknown, `mapped but not declared on-chain: ${unknown.join(", ")}`).toEqual([]);
  });

  it("covers every error a trader action can surface", () => {
    // Governance, initialisation, and internal-invariant errors are deliberately
    // unmapped: a retail user cannot trigger them, and the generic fallback
    // still shows the raw name.
    const traderFacing = CONTRACT_ERRORS.filter(
      (n) =>
        !/^(Change|Already|Not(Configurator|Controller|ReactivityPrecompile)|Unauthorized|Invalid(Facet|Bps)|Zero(Address|Denominator)|Unsupported(Decimals|CallbackEmitter)|SeriesPolicyIdentityClaimed|Loss|Recovery|Reserve|BalanceDelta|IntegrationValue|UnsafeMode|ValueOutOfBounds|TokenOperator|TokenApproval|OrderState|RestingOrder|InvalidBook|InsufficientDebtShares|PositionDepthExceeded|PositionNotLiquidatable|UnsupportedOrderType|GenerationAlreadyConfigured)/.test(
          n,
        ),
    );
    const unmapped = traderFacing.filter((n) => !mappedErrorNames().includes(n));
    expect(unmapped, `trader-facing but unmapped: ${unmapped.join(", ")}`).toEqual([]);
  });
});
