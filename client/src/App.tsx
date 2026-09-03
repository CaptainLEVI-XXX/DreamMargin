import { useState } from "react";
import { AppShell, type Route } from "./components/AppShell";
import { ProtocolAlert } from "./components/ProtocolAlert";
import type { MarketView } from "./domain/models";
import { SCENARIOS, type ScenarioName } from "./fixtures/scenarios";
import { BuilderView } from "./views/BuilderView";
import { EarnView } from "./views/EarnView";
import { MarketsView } from "./views/MarketsView";
import { PositionsView } from "./views/PositionsView";

const NAMES: ScenarioName[] = [
  "healthy",
  "atRisk",
  "resolved",
  "staleOracle",
  "reduceOnly",
  "paused",
];

export default function App() {
  const [route, setRoute] = useState<Route>("markets");
  const [scenario, setScenario] = useState<ScenarioName>("healthy");
  const [builder, setBuilder] = useState<MarketView | null>(null);
  const snapshot = SCENARIOS[scenario];

  return (
    <AppShell
      route={route}
      onNavigate={(next) => {
        setBuilder(null);
        setRoute(next);
      }}
    >
      <label className="dm-scenario">
        Protocol state
        <select value={scenario} onChange={(e) => setScenario(e.target.value as ScenarioName)}>
          {NAMES.map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
      </label>

      <ProtocolAlert protocol={snapshot.protocol} positions={snapshot.positions} />

      {route === "markets" &&
        (builder === null ? (
          <MarketsView snapshot={snapshot} onOpenBuilder={setBuilder} />
        ) : (
          <BuilderView
            market={builder}
            protocol={snapshot.protocol}
            onBack={() => setBuilder(null)}
          />
        ))}
      {route === "positions" && <PositionsView snapshot={snapshot} />}
      {route === "earn" && <EarnView vault={snapshot.vault} />}
    </AppShell>
  );
}
