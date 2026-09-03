import type { PositionView, ProtocolView } from "../domain/models";
import { PositionStatus, ProtocolMode } from "../domain/protocol";
import { Button } from "./Button";

type Props = { protocol: ProtocolView; positions: readonly PositionView[] };

type Alert = { text: string; action: string };

/**
 * Exactly one protocol-level alert, in frontend-spec §6.3's priority order.
 * Every alert names the corrective action rather than merely describing a fault.
 */
function selectAlert(protocol: ProtocolView, positions: readonly PositionView[]): Alert {
  if (protocol.wrongChain) {
    return { text: "dreammargin testnet uses Somnia Shannon", action: "Switch network" };
  }
  if (protocol.mode === ProtocolMode.Paused) {
    return { text: "New risk is paused", action: "Repay or reduce" };
  }
  if (positions.some((p) => p.bufferBps <= 0n)) {
    return { text: "A position can be liquidated now", action: "Repay" };
  }
  if (positions.some((p) => p.bufferBps > 0n && p.bufferBps < 1_000n)) {
    return { text: "A position is at risk", action: "Repay" };
  }
  if (positions.some((p) => p.status === PositionStatus.Resolved)) {
    return { text: "A resolved position is ready to settle", action: "Settle" };
  }
  if (protocol.mode === ProtocolMode.ReduceOnly) {
    return { text: "Leverage reductions only", action: "Manage positions" };
  }
  if (protocol.indexerStale) {
    return {
      text: "Market discovery may be delayed; position safety uses on-chain data",
      action: "Retry",
    };
  }
  return { text: "Somnia Shannon testnet. Values are not real money.", action: "Learn more" };
}

export function ProtocolAlert({ protocol, positions }: Props) {
  const alert = selectAlert(protocol, positions);

  return (
    <div className="dm-alert" role="status">
      <span>{alert.text}</span>
      <Button variant="secondary">{alert.action}</Button>
    </div>
  );
}
