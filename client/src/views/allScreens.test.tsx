import { render } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { assertSingleAccentFill } from "../dev/accentGuard";
import { SCENARIOS, type ScenarioName } from "../fixtures/scenarios";
import { BuilderView } from "./BuilderView";
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
    ["positions", () => <PositionsView snapshot={snapshot} />],
    ["earn", () => <EarnView vault={snapshot.vault} />],
    [
      "builder",
      () => (
        <BuilderView market={snapshot.markets[0]} protocol={snapshot.protocol} onBack={() => {}} />
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
      const { getByRole } = render(<PositionsView snapshot={SCENARIOS[name]} />);
      expect(getByRole("button", { name: /repay/i })).toBeEnabled();
    },
  );

  it.each(["paused", "reduceOnly", "staleOracle"] as ScenarioName[])(
    "disables opening with a stated reason under %s",
    (name) => {
      const s = SCENARIOS[name];
      const { getByRole, getAllByText } = render(
        <BuilderView market={s.markets[0]} protocol={s.protocol} onBack={() => {}} />,
      );
      expect(getByRole("button", { name: /add .* leverage/i })).toBeDisabled();
      expect(getAllByText(/paused|reductions only|risk data is stale/i).length).toBeGreaterThan(0);
    },
  );
});
