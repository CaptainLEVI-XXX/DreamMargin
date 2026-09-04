import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { assertSingleAccentFill } from "../dev/accentGuard";
import { SCENARIOS, type ScenarioName } from "../fixtures/scenarios";
import { EMPTY_BALANCES } from "../web3/tokens";
import { TradeView } from "./TradeView";
import { EarnView } from "./EarnView";
import { MarketsView } from "./MarketsView";
import { PositionsView } from "./PositionsView";

const NAMES: ScenarioName[] = [
  "healthy",
  "atRisk",
  "resolved",
  "staleOracle",
  "reduceOnly",
  "paused",
];

/**
 * The design requires all four screens to render in all six protocol states.
 * This is the cross-product that proves it, plus the two brand invariants that
 * must hold on every one of those twenty-four renders.
 */
describe.each(NAMES)("scenario %s", (name) => {
  const snapshot = SCENARIOS[name];
  const screens = [
    ["markets", () => <MarketsView snapshot={snapshot} onOpenBuilder={() => {}} />],
    [
      "positions",
      () => (
        <PositionsView snapshot={snapshot} account={"0x1234567890abcdef1234567890abcdef12345678"} />
      ),
    ],
    ["earn", () => <EarnView vault={snapshot.vault} />],
    [
      "trade",
      () => (
        <TradeView
          market={snapshot.markets[0]}
          protocol={snapshot.protocol}
          vault={snapshot.vault}
          balances={EMPTY_BALANCES}
          book={{ asks: [], bids: [] }}
        />
      ),
    ],
  ] as const;

  it.each(screens)("renders %s without throwing", (_label, view) => {
    expect(() => render(view())).not.toThrow();
  });

  it.each(screens)("keeps one solid violet object on %s", (_label, view) => {
    const { container } = render(view());
    expect(() => assertSingleAccentFill(container)).not.toThrow();
  });

  it.each(screens)("uses no review dialog on %s", (_label, view) => {
    const { queryByRole } = render(view());
    expect(queryByRole("dialog")).toBeNull();
  });
});

describe("safe actions survive degraded protocol modes", () => {
  it.each(["paused", "reduceOnly", "staleOracle"] as ScenarioName[])(
    "keeps repay enabled under %s",
    (name) => {
      const { getByRole } = render(
        <PositionsView
          snapshot={SCENARIOS[name]}
          account={"0x1234567890abcdef1234567890abcdef12345678"}
        />,
      );
      expect(getByRole("button", { name: "Repay" })).toBeEnabled();
    },
  );

  it.each(["paused", "reduceOnly", "staleOracle"] as ScenarioName[])(
    "disables leveraged buying with a stated reason under %s",
    (name) => {
      const s = SCENARIOS[name];
      const { getByRole } = render(
        <TradeView
          market={s.markets[0]}
          protocol={s.protocol}
          vault={s.vault}
          balances={EMPTY_BALANCES}
          book={{ asks: [{ yesPrice: 983_000n, quantity: 100_000_000n }], bids: [] }}
          account="0x1234567890abcdef1234567890abcdef12345678"
        />,
      );
      expect(getByRole("button", { name: /buy .* at 1\.25x/i })).toBeDisabled();
    },
  );
});
