import type { CapHeadroom } from "./credit";
import type { PositionStatusValue, ProtocolModeValue } from "./protocol";

/** Full DreamDEX market-generation identity. Never a pool address alone. */
export type MarketKey = {
  marketId: `0x${string}`;
  pool: `0x${string}`;
  marketNonce: bigint;
  outcomeToken: `0x${string}`;
  outcomeId: bigint;
  collateral: `0x${string}`;
};

export type MarketView = {
  key: MarketKey;
  question: string;
  asset: string;
  /** Unix seconds. */
  expiry: bigint;
  tradingStart: bigint;
  /** One whole unit of collateral, for price scaling. */
  oneCollateral: bigint;
  collateralDecimals: number;
  /** Native-unit YES price. NO price is `oneCollateral - yesPrice`. */
  yesPrice: bigint;
  /**
   * False when the market has never traded, so `yesPrice` is a midpoint
   * placeholder rather than an observation. Showing a fabricated price as though
   * it were real is worse than showing none.
   */
  priceKnown?: boolean;
  /** Conservative protocol mark. Distinct from `yesPrice` per §4.5. */
  riskMark: bigint;
  /** Size-aware executable exit value. Distinct again per §4.5. */
  estimatedExitValue: bigint;
  maxLeverageBps: bigint;
  /** Liquidation LTV from the active generation, in basis points. */
  maintenanceLtvBps?: bigint;
  riskTier: string;
  headroom: CapHeadroom;
  /** Bounded executable depth, native units. */
  visibleExitDepth: bigint;
  ownedYes: bigint;
  ownedNo: bigint;
  yesAllowance?: bigint;
  noAllowance?: bigint;
  oracleUpdatedSecondsAgo: number;
  oracleStale: boolean;
  /** Bounded on-chain DreamDEX depth, expressed in each outcome's own price. */
  book?: {
    yesBids: { price: bigint; quantity: bigint }[];
    yesAsks: { price: bigint; quantity: bigint }[];
    noBids: { price: bigint; quantity: bigint }[];
    noAsks: { price: bigint; quantity: bigint }[];
  };
};

export type PositionView = {
  positionId: bigint;
  status: PositionStatusValue;
  market: MarketView;
  outcomeIndex: 0 | 1;
  shares: bigint;
  debtAssets: bigint;
  equity: bigint;
  marketValue: bigint;
  riskValue: bigint;
  unrealizedPnl: bigint;
  bufferBps: bigint;
  liquidationPrice: bigint;
  accruedFinancing: bigint;
  annualRateBps: bigint;
  openedAt: bigint;
  riskIncreaseCutoff: bigint;
};

export type VaultView = {
  totalAssets: bigint;
  availableLiquidity: bigint;
  performingDebt: bigint;
  utilizationBps: bigint;
  protocolReserve: bigint;
  lockedReserve: bigint;
  realizedBadDebt: bigint;
  walletShares: bigint;
  walletAssets: bigint;
  maxWithdraw: bigint;
  maxRedeem: bigint;
  collateralDecimals: number;
};

export type ProtocolView = {
  mode: ProtocolModeValue;
  wrongChain: boolean;
  indexerStale: boolean;
  testnet: boolean;
};

export type AppSnapshot = {
  protocol: ProtocolView;
  markets: MarketView[];
  positions: PositionView[];
  vault: VaultView;
};
