import { useState } from "react";
import { AppShell, type Route } from "./components/AppShell";
import { ProtocolAlert } from "./components/ProtocolAlert";
import { WalletButton } from "./components/WalletButton";
import type { MarketView } from "./domain/models";
import { SCENARIOS, type ScenarioName } from "./fixtures/scenarios";
import { faucetIntent } from "./transactions/actions";
import { useIntentRunner } from "./transactions/useIntentRunner";
import { EarnView } from "./views/EarnView";
import { MarketsView } from "./views/MarketsView";
import { PositionsView } from "./views/PositionsView";
import { TradeView } from "./views/TradeView";
import { useBalances } from "./web3/useBalances";
import { useChain, useWallet } from "./web3/useChain";
import { usePositions } from "./web3/usePositions";

const SCENARIO_NAMES: ScenarioName[] = [
  "healthy",
  "atRisk",
  "resolved",
  "staleOracle",
  "reduceOnly",
  "paused",
];

/** Fixture switching is a development affordance, not part of the product. */
const SHOW_SCENARIOS = import.meta.env.DEV;

export default function App() {
  const [route, setRoute] = useState<Route>("markets");
  const [scenario, setScenario] = useState<ScenarioName>("healthy");
  const [market, setMarket] = useState<MarketView | null>(null);

  const { wallet, connect, switchChain } = useWallet();
  const account = wallet.status === "connected" ? wallet.account : null;
  const chain = useChain(account);

  const fixture = SCENARIOS[scenario];
  const primary = fixture.markets[0];
  const { balances, refresh } = useBalances(
    account,
    primary.key.outcomeId,
    primary.key.outcomeId + 1n,
  );
  const faucet = useIntentRunner(account, { atomicBatch: false }, refresh);
  const { state: positionsState, refresh: refreshPositions } = usePositions(account, primary);

  const refreshAll = () => {
    refresh();
    refreshPositions();
  };

  // Positions are only ever what the chain reports for this wallet. There is no
  // sample fallback: a card that cannot be acted on is worse than no card.
  const livePositions = positionsState.kind === "ready" ? positionsState.positions : [];
  const positionsLoading = account !== null && positionsState.kind !== "ready";

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

  const withBalances = (m: MarketView): MarketView =>
    account === null ? m : { ...m, ownedYes: balances.yes, ownedNo: balances.no };

  return (
    <AppShell
      route={route}
      onNavigate={(next) => {
        setMarket(null);
        setRoute(next);
      }}
      wallet={
        <WalletButton
          state={wallet}
          onConnect={connect}
          onSwitchChain={switchChain}
          collateral={account === null ? undefined : balances.collateral}
          onFaucet={account === null ? undefined : () => faucet.run(faucetIntent(1_000_000_000n))}
        />
      }
    >
      {SHOW_SCENARIOS ? (
        <label className="dm-scenario">
          Fixture state
          <select value={scenario} onChange={(e) => setScenario(e.target.value as ScenarioName)}>
            {SCENARIO_NAMES.map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
      ) : null}

      {chain.kind === "error" ? (
        <div className="dm-alert" role="status">
          <span>{chain.message}</span>
        </div>
      ) : (
        <ProtocolAlert protocol={snapshot.protocol} positions={livePositions} />
      )}

      {route === "markets" &&
        (market === null ? (
          <MarketsView
            snapshot={{ ...snapshot, markets: snapshot.markets.map(withBalances) }}
            onOpenBuilder={setMarket}
          />
        ) : (
          <TradeView
            market={withBalances(market)}
            protocol={snapshot.protocol}
            vault={snapshot.vault}
            balances={balances}
            book={{ asks: [], bids: [] }}
            account={account}
            onSettled={refreshAll}
            onSupplyVault={() => {
              setMarket(null);
              setRoute("earn");
            }}
          />
        ))}

      {route === "positions" && (
        <PositionsView
          snapshot={{ ...snapshot, positions: livePositions }}
          account={account}
          collateralAllowance={balances.collateralAllowance}
          outcomeAllowance={balances.yesAllowance}
          onSettled={refreshAll}
          loading={positionsLoading}
        />
      )}
      {route === "earn" && <EarnView vault={snapshot.vault} />}
    </AppShell>
  );
}
