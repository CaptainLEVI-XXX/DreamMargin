import { useState } from "react";
import { AppShell, type Route } from "./components/AppShell";
import { ProtocolAlert } from "./components/ProtocolAlert";
import { WalletButton } from "./components/WalletButton";
import type { MarketView } from "./domain/models";
import { SCENARIOS, type ScenarioName } from "./fixtures/scenarios";
import { BuilderView } from "./views/BuilderView";
import { EarnView } from "./views/EarnView";
import { MarketsView } from "./views/MarketsView";
import { PositionsView } from "./views/PositionsView";
import { useChain, useWallet } from "./web3/useChain";

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
  const { wallet, connect, switchChain } = useWallet();
  const account = wallet.status === "connected" ? wallet.account : null;
  const chain = useChain(account);

  const fixture = SCENARIOS[scenario];

  // Market discovery and positions still come from fixtures: those need the
  // indexer client and the position log scan, which land in the next plan. The
  // vault and protocol mode are already live, so they override the fixture.
  const snapshot =
    chain.kind === "ready"
      ? {
          ...fixture,
          protocol: {
            ...fixture.protocol,
            mode: chain.protocol.mode,
            wrongChain: wallet.status === "connected" && wallet.wrongChain,
          },
          vault: chain.vault,
        }
      : fixture;

  return (
    <AppShell
      route={route}
      onNavigate={(next) => {
        setBuilder(null);
        setRoute(next);
      }}
      wallet={<WalletButton state={wallet} onConnect={connect} onSwitchChain={switchChain} />}
    >
      <label className="dm-scenario">
        {chain.kind === "ready" ? "Fixture state (vault and mode are live)" : "Protocol state"}
        <select value={scenario} onChange={(e) => setScenario(e.target.value as ScenarioName)}>
          {NAMES.map((n) => (
            <option key={n} value={n}>
              {n}
            </option>
          ))}
        </select>
      </label>

      {chain.kind === "error" ? (
        <div className="dm-alert" role="status">
          <span>{chain.message}</span>
        </div>
      ) : (
        <ProtocolAlert protocol={snapshot.protocol} positions={snapshot.positions} />
      )}

      {route === "markets" &&
        (builder === null ? (
          <MarketsView snapshot={snapshot} onOpenBuilder={setBuilder} />
        ) : (
          <BuilderView
            market={builder}
            protocol={snapshot.protocol}
            onBack={() => setBuilder(null)}
            account={account}
          />
        ))}
      {route === "positions" && <PositionsView snapshot={snapshot} />}
      {route === "earn" && <EarnView vault={snapshot.vault} />}
    </AppShell>
  );
}
