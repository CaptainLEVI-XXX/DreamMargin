// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon setup library
/// @author DreamMargin contributors
/// @notice Validates live DreamDEX generations and builds conservative testnet configuration.
/// @dev This library is script-only. Every write script reconstructs the exact market generation
///      from the module before broadcasting so a recycled pool cannot be configured accidentally.

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";
import {IDreamDexBinaryModule} from "src/interfaces/integrations/IDreamDexBinaryModule.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";

import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  LibDreamMarginStorage,
  MarketKey,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {Vm} from "forge-std/Vm.sol";

// Shannon setup intentionally uses exact lifecycle and timestamp comparisons.
// forge-lint: disable-start(block-timestamp, incorrect-strict-equality, unsafe-typecast)

/// @notice Shared deployment and live-generation helpers for Shannon scripts.
library LibShannonSetup {
  /// @notice Somnia Shannon chain identifier.
  uint256 internal constant CHAIN_ID = 50_312;

  /// @notice Deployed DreamDEX binary-markets module.
  address internal constant DREAMDEX_MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;

  /// @notice Deployed Shannon tUSDC collateral with six decimals.
  address internal constant TEST_USDC = 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E;

  /// @notice Shared DreamDEX ERC-6909 outcome-token singleton.
  address internal constant OUTCOME_TOKEN = 0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9;

  /// @notice Raw units in one tUSDC or one Shannon outcome share.
  uint256 internal constant UNIT = 1e6;

  /// @notice Expected duration of a daily DreamDEX market.
  uint256 internal constant DAILY_INTERVAL = 1 days;

  /// @notice Address and constructor metadata written by the core deployment script.
  /// @param deployer Testnet-only account that deployed and initially administers the stack.
  /// @param transientProbe Contract proving transient-storage execution on Shannon.
  /// @param positionOpen Immutable position-opening facet.
  /// @param positionClose Immutable ordinary-reduction facet.
  /// @param positionLiquidation Immutable liquidation facet.
  /// @param positionSettlement Immutable terminal-settlement facet.
  /// @param vault DreamMargin ERC-4626 collateral vault.
  /// @param oracle DreamDEX generation-bound mark oracle.
  /// @param controller DreamMargin facade and shared-storage execution context.
  /// @param governanceDelay Testnet-only delay used for scheduled configuration.
  struct Deployment {
    address deployer;
    address transientProbe;
    address positionOpen;
    address positionClose;
    address positionLiquidation;
    address positionSettlement;
    address vault;
    address oracle;
    address controller;
    uint40 governanceDelay;
  }

  /// @notice Module registry record decoded as one static tuple.
  /// @param oracleQuestionId Oracle question bound to the market.
  /// @param outcomeSlotCount Number of market outcomes.
  /// @param voidPolicy Market void policy.
  /// @param collateral Collateral token.
  /// @param originOperatorId DreamDEX operator identifier.
  /// @param originVenueId DreamDEX venue identifier.
  /// @param oracleAdapter Market oracle adapter.
  /// @param creator Market creator.
  /// @param market Per-window lifecycle contract.
  /// @param pool Recyclable order-book pool.
  /// @param yesId Exact YES ERC-6909 token ID.
  /// @param noId Exact NO ERC-6909 token ID.
  /// @param tradingStart Trading-start timestamp in seconds.
  /// @param expiry Trading-expiry timestamp in seconds.
  struct ModuleMarket {
    uint256 oracleQuestionId;
    uint8 outcomeSlotCount;
    uint8 voidPolicy;
    address collateral;
    uint32 originOperatorId;
    bytes32 originVenueId;
    address oracleAdapter;
    address creator;
    address market;
    address pool;
    uint256 yesId;
    uint256 noId;
    uint64 tradingStart;
    uint64 expiry;
  }

  /// @notice Fully checked live DreamDEX daily generation.
  /// @param marketId Module-scoped market identifier.
  /// @param market Per-window market contract.
  /// @param pool Current pool binding.
  /// @param nonce Current recyclable-pool generation nonce.
  /// @param creator Market creator that rolled the generation.
  /// @param originVenueId Originating DreamDEX venue identifier.
  /// @param originOperatorId Originating DreamDEX operator identifier.
  /// @param tradingStart Trading-start timestamp in seconds.
  /// @param expiry Trading-expiry timestamp in seconds.
  /// @param yesKey Exact DreamMargin YES generation tuple.
  /// @param noKey Exact DreamMargin NO generation tuple.
  /// @param book Order-book tick, minimum-quantity, and lot-size grid.
  /// @param bestBid Current best YES bid.
  /// @param bestAsk Current best YES ask.
  struct LiveMarket {
    bytes32 marketId;
    address market;
    address pool;
    uint64 nonce;
    address creator;
    bytes32 originVenueId;
    uint32 originOperatorId;
    uint64 tradingStart;
    uint64 expiry;
    MarketKey yesKey;
    MarketKey noKey;
    IDreamDexBinaryPool.OrderBookParameters book;
    IDreamDexBinaryPool.BookLevel bestBid;
    IDreamDexBinaryPool.BookLevel bestAsk;
  }

  /// @notice Reads the actual deployed-stack manifest.
  /// @param vm Foundry cheatcode interface.
  /// @return deployment Parsed Shannon deployment.
  function readDeployment(Vm vm) internal view returns (Deployment memory deployment) {
    string memory json = vm.readFile("deployments/shannon-deployment.json");
    deployment.deployer = vm.parseJsonAddress(json, ".deployer");
    deployment.transientProbe = vm.parseJsonAddress(json, ".transientProbe");
    deployment.positionOpen = vm.parseJsonAddress(json, ".positionOpenFacet");
    deployment.positionClose = vm.parseJsonAddress(json, ".positionCloseFacet");
    deployment.positionLiquidation = vm.parseJsonAddress(json, ".positionLiquidationFacet");
    deployment.positionSettlement = vm.parseJsonAddress(json, ".positionSettlementFacet");
    deployment.vault = vm.parseJsonAddress(json, ".vault");
    deployment.oracle = vm.parseJsonAddress(json, ".oracle");
    deployment.controller = vm.parseJsonAddress(json, ".controller");
    deployment.governanceDelay = uint40(vm.parseJsonUint(json, ".governanceDelaySeconds"));
  }

  /// @notice Reads BTC and ETH daily market IDs selected by the discovery script.
  /// @param vm Foundry cheatcode interface.
  /// @return btcMarketId Selected BTC daily market ID.
  /// @return ethMarketId Selected ETH daily market ID.
  function readSelectedMarketIds(Vm vm)
    internal
    view
    returns (bytes32 btcMarketId, bytes32 ethMarketId)
  {
    string memory json = vm.readFile("deployments/shannon-selected-markets.json");
    btcMarketId = vm.parseJsonBytes32(json, ".btc.marketId");
    ethMarketId = vm.parseJsonBytes32(json, ".eth.marketId");
    require(btcMarketId != bytes32(0) && ethMarketId != bytes32(0), "EMPTY_MARKET_ID");
    require(btcMarketId != ethMarketId, "DUPLICATE_MARKET_ID");
  }

  /// @notice Validates one currently trading daily generation against every integration binding.
  /// @param marketId Module-scoped market ID selected through the DreamDEX indexer.
  /// @param expectedVenueId Required DreamDEX venue identifier.
  /// @param minimumHeadroom Minimum seconds that must remain before expiry.
  /// @return live Validated market and both exact outcome-generation keys.
  function loadLiveMarket(bytes32 marketId, bytes32 expectedVenueId, uint256 minimumHeadroom)
    internal
    view
    returns (LiveMarket memory live)
  {
    live = loadSeriesMarket(marketId, expectedVenueId, minimumHeadroom, DAILY_INTERVAL, true);
    require(uint256(live.expiry) - live.tradingStart == DAILY_INTERVAL, "NOT_DAILY");
  }

  /// @notice Validates one long-lived current generation, optionally before its book is seeded.
  /// @param marketId Module-scoped DreamDEX market identifier.
  /// @param expectedVenueId Required DreamDEX venue identifier.
  /// @param minimumHeadroom Minimum seconds that must remain before expiry.
  /// @param minimumInterval Minimum complete trading interval in seconds.
  /// @param requireDepth Whether both book sides must already cover the oracle depth.
  /// @return live Validated market and both exact outcome-generation keys.
  function loadSeriesMarket(
    bytes32 marketId,
    bytes32 expectedVenueId,
    uint256 minimumHeadroom,
    uint256 minimumInterval,
    bool requireDepth
  ) internal view returns (LiveMarket memory live) {
    ModuleMarket memory record = _marketRecord(marketId);
    require(record.originVenueId == expectedVenueId, "WRONG_VENUE");
    require(record.outcomeSlotCount == 2, "NOT_BINARY");
    require(record.collateral == TEST_USDC, "WRONG_COLLATERAL");
    require(record.expiry > record.tradingStart, "INVALID_WINDOW");
    require(uint256(record.expiry) - record.tradingStart >= minimumInterval, "INTERVAL_TOO_SHORT");
    require(uint256(record.expiry) > block.timestamp + minimumHeadroom, "INSUFFICIENT_HEADROOM");
    require(record.market.code.length != 0 && record.pool.code.length != 0, "MISSING_MARKET_CODE");
    require(IDreamDexBinaryMarket(record.market).status() == 1, "MARKET_NOT_TRADING");
    require(IDreamDexBinaryMarket(record.market).expiry() == record.expiry, "EXPIRY_MISMATCH");

    uint64 nonce = IDreamDexBinaryModule(DREAMDEX_MODULE).marketNonce(marketId);
    IDreamDexBinaryPool pool = IDreamDexBinaryPool(record.pool);
    IDreamDexBinaryPool.BinaryPoolInfo memory info = pool.getBinaryPoolParams();
    require(!info.finalized, "POOL_FINALIZED");
    require(info.market == record.market, "POOL_MARKET_MISMATCH");
    require(info.collateralToken == TEST_USDC, "POOL_COLLATERAL_MISMATCH");
    require(info.outcomeToken == OUTCOME_TOKEN, "POOL_OUTCOME_TOKEN_MISMATCH");
    require(info.yesId == record.yesId && info.noId == record.noId, "POOL_IDS_MISMATCH");
    require(info.marketNonce == nonce, "POOL_NONCE_MISMATCH");
    require(info.oneCollateral == UNIT, "POOL_UNIT_MISMATCH");
    require(IERC20Minimal(TEST_USDC).decimals() == 6, "COLLATERAL_DECIMALS");

    IDreamDexBinaryPool.OrderBookParameters memory book = pool.getOrderBookParameters();
    require(book.tickSize != 0 && book.lotSize != 0 && book.minQuantity != 0, "INVALID_GRID");
    IDreamDexBinaryPool.BookLevel[] memory bids = pool.getBookLevels(true, 1);
    IDreamDexBinaryPool.BookLevel[] memory asks = pool.getBookLevels(false, 1);
    IDreamDexBinaryPool.BookLevel memory bestBid;
    IDreamDexBinaryPool.BookLevel memory bestAsk;
    if (bids.length != 0) bestBid = bids[0];
    if (asks.length != 0) bestAsk = asks[0];
    if (requireDepth) {
      require(bids.length == 1 && asks.length == 1, "EMPTY_BOOK");
      require(bestBid.price != 0 && bestBid.price < bestAsk.price, "INVALID_BOOK");
      require(bestAsk.price < UNIT, "INVALID_ASK");
      require(bestBid.quantity >= 20 * UNIT && bestAsk.quantity >= 20 * UNIT, "SHALLOW_BOOK");
    }

    MarketKey memory yesKey = MarketKey({
      marketId: marketId,
      pool: record.pool,
      marketNonce: nonce,
      outcomeToken: OUTCOME_TOKEN,
      outcomeId: record.yesId,
      collateral: TEST_USDC
    });
    MarketKey memory noKey = MarketKey({
      marketId: marketId,
      pool: record.pool,
      marketNonce: nonce,
      outcomeToken: OUTCOME_TOKEN,
      outcomeId: record.noId,
      collateral: TEST_USDC
    });
    live = LiveMarket({
      marketId: marketId,
      market: record.market,
      pool: record.pool,
      nonce: nonce,
      creator: record.creator,
      originVenueId: record.originVenueId,
      originOperatorId: record.originOperatorId,
      tradingStart: record.tradingStart,
      expiry: record.expiry,
      yesKey: yesKey,
      noKey: noKey,
      book: book,
      bestBid: bestBid,
      bestAsk: bestAsk
    });
  }

  /// @notice Builds the deliberately bounded global Shannon demo policy.
  /// @param governanceDelay Nonzero testnet administration delay in seconds.
  /// @return config Global policy denominated in raw tUSDC units.
  function globalRisk(uint40 governanceDelay)
    internal
    pure
    returns (GlobalRiskConfig memory config)
  {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * UNIT,
      maxDailyRealizedLoss: 100 * UNIT,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: governanceDelay,
      lossWindow: 1 days,
      lossCooldown: 1 hours
    });
  }

  /// @notice Builds one exact-outcome generation policy.
  /// @param key Exact DreamDEX market-generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param marketGroup Shared BTC- or ETH-daily debt group.
  /// @return config Conservative two-times-leverage demo policy.
  function generationConfig(MarketKey memory key, uint8 outcomeIndex, bytes32 marketGroup)
    internal
    pure
    returns (GenerationConfig memory config)
  {
    config = GenerationConfig({
      key: key,
      risk: RiskConfig({
        maxDebtPerPosition: 100 * UNIT,
        maxDebtPerOutcome: 300 * UNIT,
        maxDebtPerMarket: 500 * UNIT,
        minDebt: UNIT,
        initialLtvBps: 6_000,
        maintenanceLtvBps: 7_500,
        collateralFactorBps: 8_000,
        liquidationBonusBps: 500,
        maxSpreadBps: 1_000,
        maxSlippageBps: 1_000,
        maxPositionDepthBps: 10_000,
        maxLeverageBps: 20_000,
        openingCutoff: 1_200,
        reduceOnlyCutoff: 600,
        compressionWindow: 3_600,
        maxBookLevels: 4,
        collateralDecimals: 6,
        outcomeIndex: outcomeIndex
      }),
      marketGroup: marketGroup,
      enabled: true,
      frozen: false
    });
  }

  /// @notice Builds one exact-outcome mark policy.
  /// @param key Exact DreamDEX market-generation tuple.
  /// @param minAge Minimum retained TWAP age in seconds.
  /// @param updateInterval Minimum seconds between observations.
  /// @param staleAfter Maximum newest-observation age in seconds.
  /// @return config Bounded four-level observation policy.
  function oracleConfig(
    MarketKey memory key,
    uint40 minAge,
    uint40 updateInterval,
    uint40 staleAfter
  ) internal pure returns (OracleConfig memory config) {
    config = OracleConfig({
      key: key,
      minAge: minAge,
      updateInterval: updateInterval,
      staleAfter: staleAfter,
      depthQuantity: uint128(20 * UNIT),
      maxObservations: 16,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Returns the canonical registration identifier for one generation.
  /// @param generationKey Exact DreamMargin generation hash.
  /// @return changeId Deterministic delayed-change identifier.
  function registrationChangeId(bytes32 generationKey) internal pure returns (bytes32 changeId) {
    changeId = keccak256(abi.encode("REGISTER_SHANNON_DAILY_V1", generationKey));
  }

  /// @notice Verifies every immutable dependency and the single-wallet testnet role bitmap.
  /// @param deployment Parsed deployed-stack manifest.
  function assertDeployment(Deployment memory deployment) internal view {
    IDreamMarginController controller = IDreamMarginController(deployment.controller);
    require(controller.module() == DREAMDEX_MODULE, "CONTROLLER_MODULE");
    require(controller.vault() == deployment.vault, "CONTROLLER_VAULT");
    require(controller.oracle() == deployment.oracle, "CONTROLLER_ORACLE");
    require(
      IDreamMarginVault(deployment.vault).controller() == deployment.controller, "VAULT_CONTROLLER"
    );
    require(IDreamMarginVault(deployment.vault).asset() == TEST_USDC, "VAULT_ASSET");
    require(
      IDreamDexMarkOracle(deployment.oracle).configurator() == deployment.controller,
      "ORACLE_CONFIGURATOR"
    );
    require(IDreamDexMarkOracle(deployment.oracle).module() == DREAMDEX_MODULE, "ORACLE_MODULE");
    require(deployment.controller.code.length != 0, "MISSING_CONTROLLER_CODE");
  }

  /// @notice Decodes one DreamDEX module record through its deployed ABI.
  /// @param marketId Module-scoped market identifier.
  /// @return record Complete module market record.
  function _marketRecord(bytes32 marketId) private view returns (ModuleMarket memory record) {
    (bool success, bytes memory result) =
      DREAMDEX_MODULE.staticcall(abi.encodeCall(IDreamDexBinaryModule.markets, (marketId)));
    require(success, "MODULE_MARKET_CALL");
    record = abi.decode(result, (ModuleMarket));
    require(record.market != address(0) && record.pool != address(0), "UNKNOWN_MARKET");
  }
}

// forge-lint: disable-end(block-timestamp, incorrect-strict-equality, unsafe-typecast)
