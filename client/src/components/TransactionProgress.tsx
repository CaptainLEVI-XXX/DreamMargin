import { Button } from "./Button";
import { Value } from "./Value";
import { progressSteps, type Intent } from "../transactions/machine";

/**
 * Transaction progress, rendered inside the panel that started it.
 *
 * frontend-spec §4.10 and §9.2: progress and success belong in the initiating
 * surface. Never a stack of review, approval, progress, and success modals — so
 * this component renders no dialog and traps no focus.
 */

const STATUS_WORDS = {
  ready: "Ready",
  active: "Awaiting wallet",
  complete: "Complete",
  skipped: "Skipped",
} as const;

type Props = {
  intent: Intent;
  onReview: () => void;
  onRetry: () => void;
};

export function TransactionProgress({ intent, onReview, onRetry }: Props) {
  const { state } = intent;
  const steps = progressSteps(intent);

  if (state.name === "idle") return null;

  if (state.name === "needs-review") {
    return (
      <div className="dm-progress" data-state="needs-review">
        <p className="dm-progress-headline">Review updated quote</p>
        <ul className="dm-progress-violations">
          {state.violations.map((v) => (
            <li key={v.field}>{v.explanation}</li>
          ))}
        </ul>
        <Button variant="secondary" onClick={onReview}>
          Review updated quote
        </Button>
      </div>
    );
  }

  if (state.name === "error") {
    return (
      <div className="dm-progress" data-state="error">
        <p className="dm-progress-headline">{state.message}</p>
        <Button variant="secondary" onClick={onRetry}>
          Try again
        </Button>
      </div>
    );
  }

  return (
    <div className="dm-progress" data-state={state.name}>
      <ol className="dm-progress-steps">
        {steps.map((step, i) => (
          <li key={step.label} data-status={step.status}>
            <span className="dm-progress-index">{i + 1}</span>
            <span>{step.label}</span>
            <span className="dm-progress-status">{STATUS_WORDS[step.status]}</span>
          </li>
        ))}
      </ol>

      {"hash" in state ? (
        <p className="dm-progress-hash">
          Transaction <Value>{`${state.hash.slice(0, 10)}…`}</Value>
        </p>
      ) : null}

      {state.name === "success" ? (
        <p className="dm-progress-headline">Transaction confirmed on Somnia</p>
      ) : null}
    </div>
  );
}
