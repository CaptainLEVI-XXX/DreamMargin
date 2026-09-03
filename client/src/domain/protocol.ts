/**
 * Protocol status presentation and action availability.
 *
 * frontend-spec §4.3: on a degraded or unhealthy protocol, risk-reducing
 * actions must remain reachable while risk-increasing ones are disabled with an
 * explanation. Encoding that here means no screen can get it wrong.
 */

export const PositionStatus = {
  None: 0,
  Active: 1,
  Closing: 2,
  Liquidating: 3,
  Resolved: 4,
  Closed: 5,
} as const;
export type PositionStatusValue = (typeof PositionStatus)[keyof typeof PositionStatus];

export const ProtocolMode = { Active: 0, ReduceOnly: 1, Paused: 2 } as const;
export type ProtocolModeValue = (typeof ProtocolMode)[keyof typeof ProtocolMode];

export type AvailabilityInput = {
  mode: ProtocolModeValue;
  status: PositionStatusValue;
  oracleStale: boolean;
  beforeOpeningCutoff: boolean;
  beforeReduceOnlyCutoff: boolean;
};

export type Availability = {
  canOpen: boolean;
  canBuy: boolean;
  canRepay: boolean;
  canAddCollateral: boolean;
  canDeleverage: boolean;
  canClose: boolean;
  canSettle: boolean;
  /** Plain-language reason opening is unavailable. Undefined when it is allowed. */
  openBlockedReason?: string;
};

/** Decide which actions a protocol and position state permit. */
export function availabilityFor(input: AvailabilityInput): Availability {
  const { mode, status, oracleStale, beforeOpeningCutoff, beforeReduceOnlyCutoff } = input;

  const resolved = status === PositionStatus.Resolved;
  const closed = status === PositionStatus.Closed || status === PositionStatus.None;
  const live = !resolved && !closed;

  let openBlockedReason: string | undefined;
  if (mode === ProtocolMode.Paused) openBlockedReason = "New risk is paused";
  else if (mode === ProtocolMode.ReduceOnly) openBlockedReason = "Leverage reductions only";
  else if (oracleStale) openBlockedReason = "Risk data is stale";
  else if (!beforeOpeningCutoff) openBlockedReason = "Too close to expiry for new leverage";
  else if (resolved) openBlockedReason = "Market settled";
  else if (closed) openBlockedReason = "Position closed";

  return {
    canOpen: openBlockedReason === undefined,
    canBuy: live && mode !== ProtocolMode.Paused,
    // Risk-reducing actions survive every degraded mode. §4.3
    canRepay: live,
    canAddCollateral: live,
    canDeleverage: live && beforeReduceOnlyCutoff,
    canClose: live,
    canSettle: resolved,
    openBlockedReason,
  };
}
