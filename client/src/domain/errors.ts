/**
 * Contract error to recovery copy.
 *
 * frontend-spec §15 and integration guide §13: never show "Something went
 * wrong" when the contract named a specific reason, and always keep the raw
 * name available behind technical detail.
 *
 * Error names are validated against the generated `errorsAbi` in this module's
 * test, so a renamed or removed contract error fails the suite rather than
 * silently degrading to generic copy.
 */

export type ErrorCopy = {
  message: string;
  recovery: string;
  /** Whether the client has specific copy, as opposed to a generic fallback. */
  known: boolean;
  /** The decoded contract error name, always preserved. */
  raw: string;
};

const TABLE: Record<string, { message: string; recovery: string }> = {
  ActionBlocked: {
    message: "New leverage is unavailable in the current protocol mode",
    recovery: "Manage or repay positions",
  },
  UnsupportedGeneration: {
    message: "This market generation is not supported for leverage",
    recovery: "Buy without leverage or choose another market",
  },
  UnsupportedSeriesIdentity: {
    message: "This market was not created by an approved DreamMargin series",
    recovery: "Choose a supported BTC or ETH market",
  },
  UnsupportedSeriesPolicy: {
    message: "Leverage is disabled for this market series",
    recovery: "Buy without leverage or choose another market",
  },
  SeriesPolicyFrozen: {
    message: "New leverage for this market series is frozen",
    recovery: "Repay, close, or buy without leverage",
  },
  SeriesIntervalTooShort: {
    message: "This market expires too soon to support leverage safely",
    recovery: "Choose a long-duration DreamMargin market",
  },
  GenerationFrozen: {
    message: "New risk for this outcome is frozen",
    recovery: "Repay, close, or choose another market",
  },
  GenerationMismatch: {
    message: "This market generation no longer matches the one reviewed",
    recovery: "Refresh markets",
  },
  PoolRecycled: {
    message: "DreamDEX has moved this pool to a new market generation",
    recovery: "Refresh markets",
  },
  InvalidMarketStatus: {
    message: "This market is no longer trading",
    recovery: "View settlement state",
  },
  MarketExpired: {
    message: "This market has expired",
    recovery: "View settlement state",
  },
  OracleNotReady: {
    message: "Risk history is still building",
    recovery: "Retry after the displayed minimum age",
  },
  StaleOracle: {
    message: "Risk data is stale",
    recovery: "Retry; repay and add collateral remain available",
  },
  ObservationTooSoon: {
    message: "The last risk observation is too recent to add another",
    recovery: "Retry after the update interval",
  },
  OpeningCutoffReached: {
    message: "This market is too close to expiry for new leverage",
    recovery: "Buy normally or manage existing positions",
  },
  InvalidTick: {
    message: "The quote no longer matches the market grid",
    recovery: "Refresh quote",
  },
  InvalidLot: {
    message: "The quote no longer matches the market grid",
    recovery: "Refresh quote",
  },
  QuantizedToZero: {
    message: "The requested size rounds to zero on this market's grid",
    recovery: "Increase size",
  },
  QuantityBelowMinimum: {
    message: "The requested size is below this market's minimum",
    recovery: "Increase size",
  },
  InsufficientBookDepth: {
    message: "The requested size is larger than supported liquidity",
    recovery: "Reduce size",
  },
  InsufficientSharesOut: {
    message: "The market moved beyond the selected minimum fill",
    recovery: "Refresh or loosen bounds explicitly",
  },
  DebtCapExceeded: {
    message: "The position or market credit limit has been reached",
    recovery: "Reduce leverage or try later",
  },
  UtilizationExceeded: {
    message: "The vault has insufficient available lending capacity",
    recovery: "Reduce leverage or try later",
  },
  InsufficientHealth: {
    message: "The resulting position would be too risky",
    recovery: "Add shares or reduce leverage",
  },
  RepaymentLimitExceeded: {
    message: "The repayment or close needs more collateral than authorized",
    recovery: "Refresh debt and review a new maximum",
  },
  IncompleteClose: {
    message: "The full position could not close within the selected bounds",
    recovery: "Refresh book or choose repay-and-withdraw",
  },
  InsufficientLiquidity: {
    message: "The vault cannot provide the requested cash now",
    recovery: "Withdraw the displayed available amount",
  },
  SettlementNotFinal: {
    message: "DreamDEX has not finalized this market yet",
    recovery: "Retry after finalization",
  },
  PositionNotFound: {
    message: "This position no longer exists",
    recovery: "Return to positions",
  },
  NotPositionOwner: {
    message: "Only the position owner can take this action",
    recovery: "Switch to the owning wallet",
  },
  InvalidPositionStatus: {
    message: "This position is not in a state that allows the action",
    recovery: "Refresh the position",
  },
  DeadlineExpired: {
    message: "The quote deadline passed before the transaction landed",
    recovery: "Refresh quote",
  },
  OrderDeadlineExceeded: {
    message: "The order deadline passed before the market could fill it",
    recovery: "Refresh quote",
  },
  OrderRejected: {
    message: "DreamDEX rejected the order",
    recovery: "Refresh quote and review the bounds",
  },
  ExcessiveCollateralIn: {
    message: "The trade would spend more collateral than authorized",
    recovery: "Refresh quote and review a new maximum",
  },
  InsufficientOutcomeAllowance: {
    message: "The approved outcome amount is not enough for this action",
    recovery: "Approve the exact amount shown",
  },
  InsufficientShareAllowance: {
    message: "The approved vault-share amount is not enough for this action",
    recovery: "Approve the exact amount shown",
  },
  InsufficientPositionShares: {
    message: "The position holds fewer shares than requested",
    recovery: "Reduce the amount",
  },
  InsufficientVaultShares: {
    message: "Your vault-share balance is lower than requested",
    recovery: "Reduce the amount",
  },
  ZeroAmount: {
    message: "This action needs a non-zero amount",
    recovery: "Enter an amount",
  },
};

/** Map a decoded custom-error name to user-facing copy, preserving the raw name. */
export function describeContractError(name: string): ErrorCopy {
  const hit = TABLE[name];
  if (hit !== undefined) return { ...hit, known: true, raw: name };
  return {
    message: `The contract rejected this action: ${name}`,
    recovery: "Review inputs and try again",
    known: false,
    raw: name,
  };
}

/** Error names this client has specific copy for. Used by the drift test. */
export function mappedErrorNames(): string[] {
  return Object.keys(TABLE);
}
