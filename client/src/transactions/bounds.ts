/**
 * The reviewed-bounds gate.
 *
 * frontend-spec §4.8 and integration guide §12 permit the orchestrator to
 * request the second wallet signature without another application click — but
 * only while the refreshed request stays inside every economic bound the user
 * actually saw. If any bound worsened, the sequence stops for a new review.
 *
 * This is the difference between the specification's promise and a client that
 * quietly signs something worse than what was displayed, so it is a pure
 * function over bigints with no chain or React dependency.
 */

export type TradeSide = "buy" | "sell";

export type Bounds = {
  /** Direction, which decides whether a higher limit price is better or worse. */
  side?: TradeSide;
  /** Maximum collateral the user agreed to spend. */
  maxCollateralIn?: bigint;
  /** Minimum outcome shares the user agreed to accept. */
  minSharesOut?: bigint;
  /** Limit price, always in the YES-price convention. */
  limitPrice?: bigint;
  /** Safety buffer displayed before signing, in basis points. */
  minSafetyBufferBps?: bigint;
  /** Maximum collateral authorised for a repayment or close. */
  maxRepayAssets?: bigint;
  /** Minimum collateral the user agreed to receive from a sale. */
  minCollateralOut?: bigint;
  /** Quote deadline, unix seconds. */
  deadline?: bigint;
};

export type BoundsViolation = {
  field: keyof Bounds;
  reviewed: bigint;
  fresh: bigint;
  explanation: string;
};

export type BoundsCheck = { ok: true } | { ok: false; violations: BoundsViolation[] };

type Direction = "must-not-increase" | "must-not-decrease";

const NUMERIC_RULES: {
  field: keyof Bounds;
  direction: Direction;
  explanation: string;
}[] = [
  {
    field: "maxCollateralIn",
    direction: "must-not-increase",
    explanation: "The trade now costs more than the maximum you reviewed",
  },
  {
    field: "maxRepayAssets",
    direction: "must-not-increase",
    explanation: "The repayment now needs more collateral than you authorised",
  },
  {
    field: "minSharesOut",
    direction: "must-not-decrease",
    explanation: "The trade now guarantees fewer shares than you reviewed",
  },
  {
    field: "minCollateralOut",
    direction: "must-not-decrease",
    explanation: "The sale now guarantees less collateral than you reviewed",
  },
  {
    field: "minSafetyBufferBps",
    direction: "must-not-decrease",
    explanation: "The resulting position is riskier than the one you reviewed",
  },
];

function violates(direction: Direction, reviewed: bigint, fresh: bigint): boolean {
  return direction === "must-not-increase" ? fresh > reviewed : fresh < reviewed;
}

/**
 * Compare a refreshed request against what the user reviewed.
 *
 * A bound present in the review but absent from the refreshed request counts as
 * a violation: dropping a protection is not an improvement. A bound that only
 * appears in the refreshed request is ignored, since the user was never shown it
 * and it cannot have got worse.
 */
export function checkBounds(reviewed: Bounds, fresh: Bounds, nowSeconds: bigint): BoundsCheck {
  const violations: BoundsViolation[] = [];

  for (const { field, direction, explanation } of NUMERIC_RULES) {
    const before = reviewed[field] as bigint | undefined;
    if (before === undefined) continue;

    const after = fresh[field] as bigint | undefined;
    if (after === undefined) {
      violations.push({
        field,
        reviewed: before,
        fresh: before,
        explanation: "A protection you reviewed is missing from the refreshed request",
      });
      continue;
    }

    if (violates(direction, before, after)) {
      violations.push({ field, reviewed: before, fresh: after, explanation });
    }
  }

  // A limit price is only comparable with a known direction. Buying at a higher
  // price is worse; selling at a lower one is worse.
  if (reviewed.limitPrice !== undefined) {
    const after = fresh.limitPrice;
    if (after === undefined) {
      violations.push({
        field: "limitPrice",
        reviewed: reviewed.limitPrice,
        fresh: reviewed.limitPrice,
        explanation: "A protection you reviewed is missing from the refreshed request",
      });
    } else if (reviewed.side === undefined) {
      if (after !== reviewed.limitPrice) {
        violations.push({
          field: "limitPrice",
          reviewed: reviewed.limitPrice,
          fresh: after,
          explanation: "The price limit changed and its direction is unknown",
        });
      }
    } else {
      const worse =
        reviewed.side === "buy" ? after > reviewed.limitPrice : after < reviewed.limitPrice;
      if (worse) {
        violations.push({
          field: "limitPrice",
          reviewed: reviewed.limitPrice,
          fresh: after,
          explanation: "The price moved beyond the limit you reviewed",
        });
      }
    }
  }

  // An expired quote is always a violation, however favourable the numbers look.
  if (reviewed.deadline !== undefined && nowSeconds >= reviewed.deadline) {
    violations.push({
      field: "deadline",
      reviewed: reviewed.deadline,
      fresh: nowSeconds,
      explanation: "The quote expired before the transaction was sent",
    });
  }

  return violations.length === 0 ? { ok: true } : { ok: false, violations };
}
