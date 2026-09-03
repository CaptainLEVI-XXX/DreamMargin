import { formatBps } from "../domain/amounts";
import { riskStateFromBufferBps } from "../domain/risk";
import { Value } from "./Value";

type Props = {
  /** Safety buffer in basis points. May be negative when liquidatable. */
  bufferBps: bigint;
  /** Preformatted liquidation boundary, for example "48¢". */
  liquidationLabel: string;
  /** Age of the newest risk observation, in seconds. */
  updatedSecondsAgo: number;
  /** Whether the observation is past its freshness window. */
  stale?: boolean;
};

/**
 * A horizontal buffer bar with text, as frontend-spec §8.4 requires — not a
 * circular score, and never colour alone. Geometry stays fixed as risk
 * escalates; only the semantic colour and the label change.
 */
export function SafetyBuffer({ bufferBps, liquidationLabel, updatedSecondsAgo, stale }: Props) {
  const state = riskStateFromBufferBps(bufferBps);
  const clamped = bufferBps < 0n ? 0n : bufferBps > 10_000n ? 10_000n : bufferBps;
  const percent = Number(clamped) / 100;

  return (
    <div className="dm-buffer" data-level={state.level}>
      <div className="dm-buffer-head">
        <span>
          Safety buffer <Value>{formatBps(clamped)}</Value>
        </span>
        <span>
          Liquidation near <Value>{liquidationLabel}</Value>
        </span>
      </div>

      <div
        className="dm-buffer-track"
        role="meter"
        aria-label="Safety buffer"
        aria-valuenow={percent}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuetext={`${percent}%, ${state.label}`}
      >
        <div className="dm-buffer-fill" style={{ width: `${percent}%` }} />
      </div>

      <div className="dm-buffer-foot">
        <span className="dm-buffer-state">
          <span aria-hidden="true">{state.icon}</span> {state.label}
        </span>
        <span>{stale === true ? "Risk data stale" : `Updated ${updatedSecondsAgo}s ago`}</span>
      </div>
    </div>
  );
}
