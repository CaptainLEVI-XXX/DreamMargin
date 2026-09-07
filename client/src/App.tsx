import { useState } from "react";
import { AppShell, type Route } from "./components/AppShell";
import { HeaderFunds } from "./components/HeaderFunds";
import { ProtocolAlert } from "./components/ProtocolAlert";
import { WalletButton } from "./components/WalletButton";
import type { MarketView } from "./domain/models";
import { SCENARIOS } from "./fixtures/scenarios";
import { faucetIntent } from "./transactions/actions";
import { useIntentRunner } from "./transactions/useIntentRunner";
import { EarnView } from "./views/EarnView";
import { MarketsView } from "./views/MarketsView";
import { PositionsView } from "./views/PositionsView";
import { TradeView } from "./views/TradeView";
import { useBalances } from "./web3/useBalances";
import { useChain, useWallet } from "./web3/useChain";
import { useMarkets } from "./web3/useMarkets";
import { useIndexSeries } from "./data/useIndexSeries";
import { usePositions } from "./web3/usePositions";

export default function App() {
  const [route, setRoute] = useState<Route>("markets");
  const [market, setMarket] = useState<MarketView | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { wallet, connect, switchChain, disconnect } = useWallet();
  const account = wallet.status === "connected" ? wallet.account : null;
  const discovered = useMarkets(account, refreshKey);
  const chain = useChain(account, refreshKey);

  const fixture = SCENARIOS.healthy;
  const liveMarkets = discovered.kind === "ready" ? discovered.markets : [];

  // Every live market is BTC or ETH, so two underlying series cover every row's
  // sparkline rather than one request per market.
  const btc = useIndexSeries("BTC", 0n, "M1", 20);
  const eth = useIndexSeries("ETH", 0n, "M1", 20);
  const sparks = {
    BTC: btc.kind === "ready" ? btc.series.points : [],
    ETH: eth.kind === "ready" ? eth.series.points : [],
  };
  const sparkStates = { BTC: btc.kind, ETH: eth.kind } as const;
  const primary = liveMarkets[0] ?? fixture.markets[0];
  const selectedMarket =
    market === null
      ? null
      : (liveMarkets.find(
          (candidate) => candidate.key.marketId.toLowerCase() === market.key.marketId.toLowerCase(),
        ) ?? market);
  const selected = selectedMarket ?? primary;
  const { balances, refresh } = useBalances(
    account,
    selected.key.outcomeId,
    selected.key.outcomeId + 1n,
    selected.key.pool as `0x${string}`,
  );
  const faucet = useIntentRunner(account, { atomicBatch: false }, refresh);
  const { state: positionsState, refresh: refreshPositions } = usePositions(account, liveMarkets);

  const refreshAll = () => {
    refresh();
    refreshPositions();
    setRefreshKey((current) => current + 1);
  };

  // Positions are only ever what the chain reports for this wallet. There is no
  // sample fallback: a card that cannot be acted on is worse than no card.
  const livePositions =
    account !== null && positionsState.kind === "ready" ? positionsState.positions : [];
  const positionsLoading =
    account !== null && (positionsState.kind === "idle" || positionsState.kind === "loading");
  const positionsError = positionsState.kind === "error" ? positionsState.message : undefined;

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
        setMarket(null);
        setRoute(next);
      }}
      utilities={
        account === null ? null : (
          <HeaderFunds
            collateral={balances.collateral}
            onFaucet={() => faucet.run(faucetIntent(1_000_000_000n, balances.collateralAllowance))}
          />
        )
      }
      wallet={
        <WalletButton
          state={wallet}
          onConnect={connect}
          onSwitchChain={switchChain}
          onDisconnect={disconnect}
        />
      }
    >
      {chain.kind === "error" ? (
        <div className="dm-alert" role="status">
          <span>{chain.message}</span>
        </div>
      ) : (
        <ProtocolAlert protocol={snapshot.protocol} positions={livePositions} />
      )}

      {route === "markets" &&
        (selectedMarket === null ? (
          <MarketsView
            snapshot={{ ...snapshot, markets: liveMarkets }}
            onOpenBuilder={setMarket}
            loading={discovered.kind === "loading"}
            error={discovered.kind === "error" ? discovered.message : undefined}
            sparks={sparks}
            sparkStates={sparkStates}
          />
        ) : (
          <TradeView
            market={{ ...selectedMarket, ownedYes: balances.yes, ownedNo: balances.no }}
            protocol={snapshot.protocol}
            vault={snapshot.vault}
            balances={balances}
            book={{
              asks:
                selectedMarket.book?.yesAsks.map((level) => ({
                  yesPrice: level.price,
                  quantity: level.quantity,
                })) ?? [],
              bids:
                selectedMarket.book?.yesBids.map((level) => ({
                  yesPrice: level.price,
                  quantity: level.quantity,
                })) ?? [],
            }}
            account={account}
            onSettled={refreshAll}
            onBack={() => setMarket(null)}
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
          onSettled={refreshAll}
          loading={positionsLoading}
          error={positionsError}
        />
      )}
      {route === "earn" && (
        <EarnView
          vault={snapshot.vault}
          account={account}
          balances={balances}
          onSettled={refreshAll}
        />
      )}
    </AppShell>
  );
}
