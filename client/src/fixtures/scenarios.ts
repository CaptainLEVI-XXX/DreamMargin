import type { AppSnapshot, MarketKey, MarketView, PositionView, VaultView } from "../domain/models";
import { PositionStatus, ProtocolMode } from "../domain/protocol";

/**
 * Six protocol states, typed exactly as the real contract reads will be so the
 * data source can be swapped without touching a component. Values mirror the
 * live Shannon deployment: 6-decimal collateral, 2.0x maximum leverage, a
 * 100 tUSDC per-position cap, and the registered daily market keys.
 */

const USDC = 1_000_000n;

const ETH_YES: MarketKey = {
  marketId: "0x0000000000000000000000000000000000000000000000000000000000011ad6",
  pool: "0x246a65643ad8b6c6dbd0b017a259da07681242fd",
  marketNonce: 106n,
  outcomeToken: "0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9",
  outcomeId: 981762892987552592529876415592559547602498254264742346774773393025536n,
  collateral: "0x70a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e",
};

const BTC_YES: MarketKey = {
  marketId: "0x0000000000000000000000000000000000000000000000000000000000011ad5",
  pool: "0x8eb893db72752b1d2b3ac11f625af90db1beb404",
  marketNonce: 68n,
  outcomeToken: "0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9",
  outcomeId: 3847750713332781179217769380546506427338652337229629986951389423617024n,
  collateral: "0x70a86d8842fb63c4ad2b7cdddf530ebf1bb25d8e",
};

function market(over: Partial<MarketView> & { key: MarketKey; question: string }): MarketView {
  return {
    asset: "ETH",
    expiry: 1_788_480_000n,
    tradingStart: 1_788_393_600n,
    oneCollateral: USDC,
    collateralDecimals: 6,
    yesPrice: 620_000n,
    riskMark: 605_000n,
    noRiskMark: 375_000n,
    estimatedExitValue: 598_000n,
    maxLeverageBps: 20_000n,
    riskTier: "Standard",
    headroom: {
      position: 100n * USDC,
      outcome: 300n * USDC,
      market: 500n * USDC,
      global: 1_000n * USDC,
      utilization: 800n * USDC,
      vaultCash: 418n * USDC,
    },
    visibleExitDepth: 12_400n * USDC,
    ownedYes: 0n,
    ownedNo: 0n,
    oracleUpdatedSecondsAgo: 18,
    oracleStale: false,
    ...over,
  };
}

const ethMarket = market({
  key: ETH_YES,
  question: "Will ETH close at or above its opening price?",
  ownedYes: 240_000_000n,
});

const btcMarket = market({
  key: BTC_YES,
  question: "Will BTC close at or above its opening price?",
  asset: "BTC",
  yesPrice: 480_000n,
  riskMark: 470_000n,
  noRiskMark: 510_000n,
  estimatedExitValue: 462_000n,
});

const vault: VaultView = {
  totalAssets: 1_420_000n * USDC,
  availableLiquidity: 418_000n * USDC,
  performingDebt: 965_600n * USDC,
  utilizationBps: 6_800n,
  protocolReserve: 42_000n * USDC,
  lockedReserve: 12_000n * USDC,
  realizedBadDebt: 1_200n * USDC,
  walletShares: 986_400_000n,
  walletAssets: 1_000n * USDC,
  maxWithdraw: 1_000n * USDC,
  maxRedeem: 986_400_000n,
  collateralDecimals: 6,
};

const healthyPosition: PositionView = {
  positionId: 1842n,
  status: PositionStatus.Active,
  market: ethMarket,
  outcomeIndex: 0,
  shares: 381_000_000n,
  debtAssets: 102_800_000n,
  equity: 121_300_000n,
  marketValue: 236_220_000n,
  riskValue: 224_100_000n,
  unrealizedPnl: 18_400_000n,
  bufferBps: 4_000n,
  liquidationPrice: 480_000n,
  accruedFinancing: 1_840_000n,
  annualRateBps: 500n,
  openedAt: 1_788_386_000n,
  riskIncreaseCutoff: 1_788_478_800n,
};

const base: AppSnapshot = {
  protocol: { mode: ProtocolMode.Active, wrongChain: false, indexerStale: false, testnet: true },
  markets: [ethMarket, btcMarket],
  positions: [healthyPosition],
  vault,
};

const staleEth = { ...ethMarket, oracleStale: true, oracleUpdatedSecondsAgo: 6858 };
const staleBtc = { ...btcMarket, oracleStale: true, oracleUpdatedSecondsAgo: 6858 };

export type ScenarioName =
  "healthy" | "atRisk" | "resolved" | "staleOracle" | "reduceOnly" | "paused";

export const SCENARIOS: Record<ScenarioName, AppSnapshot> = {
  healthy: base,

  atRisk: {
    ...base,
    positions: [
      {
        ...healthyPosition,
        bufferBps: 600n,
        debtAssets: 108_200_000n,
        unrealizedPnl: -32_100_000n,
      },
    ],
  },

  resolved: {
    ...base,
    positions: [{ ...healthyPosition, status: PositionStatus.Resolved, bufferBps: 10_000n }],
  },

  staleOracle: {
    ...base,
    markets: [staleEth, staleBtc],
    positions: [{ ...healthyPosition, market: staleEth }],
  },

  reduceOnly: { ...base, protocol: { ...base.protocol, mode: ProtocolMode.ReduceOnly } },

  paused: { ...base, protocol: { ...base.protocol, mode: ProtocolMode.Paused } },
};
