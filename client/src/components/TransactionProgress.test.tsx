import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { TransactionProgress } from "./TransactionProgress";
import { buildCallPlan } from "../transactions/callPlan";
import { createIntent, transition, type Intent, type IntentEvent } from "../transactions/machine";
import type { Bounds } from "../transactions/bounds";

const CONTROLLER = "0x50B054bD4A891C44A66c86e8c82A45AE0630869c" as const;
const NOW = 1_000_000n;
const reviewed: Bounds = { maxCollateralIn: 100n, deadline: NOW + 60n };

const plan = buildCallPlan({
  action: { to: CONTROLLER, label: "Open 2x position" },
  erc6909: {
    token: CONTROLLER,
    spender: CONTROLLER,
    outcomeId: 1n,
    required: 200n,
    current: 0n,
    label: "Approve 200 YES only",
  },
});

function run(events: IntentEvent[]): Intent {
  return events.reduce(transition, createIntent(reviewed));
}

const noop = () => {};

describe("TransactionProgress", () => {
  it("renders nothing before the intent starts", () => {
    const { container } = render(
      <TransactionProgress intent={createIntent(reviewed)} onReview={noop} onRetry={noop} />,
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("lists both decoded calls once planned", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={noop} />);
    expect(screen.getByText("Approve 200 YES only")).toBeVisible();
    expect(screen.getByText("Open 2x position")).toBeVisible();
  });

  it("shows the transaction hash as soon as one exists", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
      { type: "approval-submitted", hash: "0xabcdef1234567890" },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={noop} />);
    expect(screen.getByText(/0xabcdef12/)).toBeVisible();
  });

  it("explains each violation when it stops for review", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
      { type: "refresh-complete", fresh: { maxCollateralIn: 999n }, nowSeconds: NOW },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={noop} />);
    expect(screen.getByText(/costs more than the maximum you reviewed/i)).toBeVisible();
    expect(screen.getByRole("button", { name: /review updated quote/i })).toBeVisible();
  });

  it("offers recovery on a failure without discarding the intent", () => {
    const onRetry = vi.fn();
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
      { type: "failed", message: "Risk data is stale" },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={onRetry} />);
    expect(screen.getByText("Risk data is stale")).toBeVisible();
    expect(screen.getByRole("button", { name: /try again/i })).toBeVisible();
  });

  it("announces success only after reconciliation", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
      { type: "approval-submitted", hash: "0xaaa" },
      { type: "approval-confirmed" },
      { type: "refresh-complete", fresh: { ...reviewed }, nowSeconds: NOW },
      { type: "action-submitted", hash: "0xbbb" },
      { type: "action-confirmed" },
      { type: "event-verified" },
      { type: "reconciled" },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={noop} />);
    expect(screen.getByText(/confirmed on somnia/i)).toBeVisible();
    expect(screen.getByRole("button", { name: /continue/i })).toBeVisible();
  });

  it("never opens a dialog, keeping progress in the initiating surface", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
    ]);
    render(<TransactionProgress intent={intent} onReview={noop} onRetry={noop} />);
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("keeps the violet fill for the page's primary action", () => {
    const intent = run([
      { type: "start" },
      { type: "plan-ready", plan, capabilities: { atomicBatch: false } },
      { type: "failed", message: "boom" },
    ]);
    const { container } = render(
      <TransactionProgress intent={intent} onReview={noop} onRetry={noop} />,
    );
    expect(container.querySelectorAll("[data-accent-fill]")).toHaveLength(0);
  });
});
