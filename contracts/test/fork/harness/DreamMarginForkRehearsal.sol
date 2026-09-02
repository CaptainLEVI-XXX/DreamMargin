// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin pinned-source fork rehearsal
/// @author DreamMargin contributors
/// @notice Deploys the real protocol stack around a controlled mirror of one pinned DreamDEX market.
/// @dev Real DreamDEX reads provide identity, price, expiry, and grid inputs. Mock contracts provide
///      write liquidity because the public RPC cannot create a Foundry state fork and the rehearsal
///      intentionally uses no funded Shannon account or test tokens.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {PositionSettlement} from "src/dreammargin/base/PositionSettlement.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  LibDreamMarginStorage,
  MarketKey,
  Position,
  PositionStatus,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {ShannonSnapshot} from "test/fork/harness/ShannonSnapshot.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockDreamDexBinarySettlement} from "test/mock/MockDreamDexBinarySettlement.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Vm} from "forge-std/Vm.sol";

// Cheatcodes are the explicit boundary of this local-only deployment rehearsal.
// forge-lint: disable-start(unsafe-cheatcode, unsafe-typecast, unused-return, block-timestamp, incorrect-strict-equality)

/// @notice Machine-readable result emitted by the rehearsal script.
/// @param sourceFingerprint Hash of the pinned deployed DreamDEX inputs.
/// @param generationKey Local mirror's full generation key.
/// @param sourceModule Deployed DreamDEX module read at the pinned block.
/// @param sourceMarket Deployed DreamDEX market read at the pinned block.
/// @param sourcePool Deployed DreamDEX pool read at the pinned block.
/// @param mirrorModule Local write-capable DreamDEX module model.
/// @param mirrorMarket Local write-capable DreamDEX market model.
/// @param mirrorPool Local write-capable DreamDEX pool model.
/// @param collateral Local mintable collateral used only by the rehearsal.
/// @param outcomeToken Local mintable exact-ID token used only by the rehearsal.
/// @param vault Real DreamMargin vault deployment.
/// @param oracle Real DreamMargin oracle deployment.
/// @param controller Real DreamMargin controller deployment.
/// @param positionOpenFacet Real immutable opening facet.
/// @param positionCloseFacet Real immutable ordinary-exit facet.
/// @param positionLiquidationFacet Real immutable liquidation facet.
/// @param positionSettlementFacet Real immutable settlement facet.
/// @param positionId Position opened and closed by the smoke flow.
/// @param lpAssetsDeposited Assets supplied at the beginning of the smoke flow.
/// @param lpAssetsWithdrawn Assets withdrawn after all position debt reached zero.
struct ForkRehearsalResult {
  bytes32 sourceFingerprint;
  bytes32 generationKey;
  address sourceModule;
  address sourceMarket;
  address sourcePool;
  address mirrorModule;
  address mirrorMarket;
  address mirrorPool;
  address collateral;
  address outcomeToken;
  address vault;
  address oracle;
  address controller;
  address positionOpenFacet;
  address positionCloseFacet;
  address positionLiquidationFacet;
  address positionSettlementFacet;
  uint256 positionId;
  uint256 lpAssetsDeposited;
  uint256 lpAssetsWithdrawn;
}

/// @notice Runs one complete locally funded DreamMargin deployment and lifecycle rehearsal.
contract DreamMarginForkRehearsal {
  Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _LP = address(0x2001);
  address private constant _TRADER = address(0x2002);
  bytes32 private constant _MARKET_GROUP = keccak256("SHANNON_FORK_REHEARSAL");
  uint40 private constant _GOVERNANCE_DELAY = 1 days;

  /// @notice Deploys, binds, configures, and exercises the complete smoke lifecycle.
  /// @param source Pinned deployed DreamDEX inputs copied into the local model.
  /// @return result Addresses and accounting outputs serialized by the script.
  function run(ShannonSnapshot memory source) external returns (ForkRehearsalResult memory result) {
    require(source.oneCollateral == 1e6, "SOURCE_DECIMALS");
    require(source.expiry > 8 days, "SOURCE_EXPIRY");
    _VM.warp(source.expiry - 7 days);

    MockERC20 collateral = new MockERC20("Mirrored DreamDEX USD", "mUSD", 6);
    MockERC6909 outcome = new MockERC6909();
    MockDreamDexBinarySettlement settlement = new MockDreamDexBinarySettlement(address(outcome));
    MockDreamDexBinaryMarket market = new MockDreamDexBinaryMarket(
      address(outcome), source.yesId, source.noId, address(1), address(collateral), source.expiry
    );
    IDreamDexBinaryPool.BinaryPoolInfo memory poolInfo = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(collateral),
      market: address(market),
      outcomeToken: address(outcome),
      yesId: source.yesId,
      noId: source.noId,
      oneCollateral: source.oneCollateral,
      setBacking: source.setBacking,
      feeRecipient: _FEE_RECIPIENT,
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: address(settlement),
      marketNonce: source.marketNonce,
      finalized: false
    });
    MockDreamDexBinaryPool pool =
      new MockDreamDexBinaryPool(poolInfo, source.grid, source.marketExpiryNs);
    market.setPool(address(pool));
    MockDreamDexBinaryModule module = new MockDreamDexBinaryModule(address(settlement));
    module.setMarket(
      source.marketId,
      source.marketNonce,
      MockModuleMarket({
        oracleQuestionId: 1,
        outcomeSlotCount: 2,
        voidPolicy: 0,
        collateral: address(collateral),
        originOperatorId: 2,
        originVenueId: keccak256("PINNED_SHANNON_SOURCE"),
        oracleAdapter: address(0xA11),
        creator: address(0xC0DE),
        market: address(market),
        pool: address(pool),
        yesId: source.yesId,
        noId: source.noId,
        tradingStart: source.tradingStart,
        expiry: source.expiry
      })
    );
    _seedBook(pool, source);

    PositionOpen positionOpen = new PositionOpen();
    PositionClose positionClose = new PositionClose();
    PositionLiquidation positionLiquidation = new PositionLiquidation();
    PositionSettlement positionSettlement = new PositionSettlement();
    uint256 nextNonce = _VM.getNonce(address(this));
    address predictedController = _VM.computeCreateAddress(address(this), nextNonce + 2);
    DreamMarginVault vault = new DreamMarginVault(address(collateral), predictedController, 0.05e18);
    DreamDexMarkOracle oracle = new DreamDexMarkOracle(address(module), predictedController);
    DreamMarginController controller = new DreamMarginController(
      address(module),
      address(vault),
      address(oracle),
      _FEE_RECIPIENT,
      address(positionOpen),
      address(positionClose),
      address(positionLiquidation),
      address(positionSettlement),
      _roles(),
      _globalRisk(source.oneCollateral)
    );
    require(address(controller) == predictedController, "CONTROLLER_ADDRESS");
    _assertBindings(controller, vault, oracle, module);

    MarketKey memory key = MarketKey({
      marketId: source.marketId,
      pool: address(pool),
      marketNonce: source.marketNonce,
      outcomeToken: address(outcome),
      outcomeId: source.yesId,
      collateral: address(collateral)
    });
    bytes32 generationKey = LibDreamMarginStorage.generationKey(key);
    GenerationConfig memory generation = _generation(key, source.oneCollateral);
    OracleConfig memory oracleConfig = _oracleConfig(key, source.oneCollateral);
    bytes32 changeId = keccak256("REGISTER_PINNED_SHANNON_MIRROR");
    _VM.prank(_RISK_STEWARD);
    controller.scheduleGenerationChange(changeId, generationKey, generation, oracleConfig);
    _VM.warp(block.timestamp + _GOVERNANCE_DELAY);
    controller.executeGenerationChange(changeId, generationKey, generation, oracleConfig);
    require(controller.getGeneration(generationKey).enabled, "GENERATION_DISABLED");

    oracle.observe(generationKey);
    _VM.warp(block.timestamp + 60);
    oracle.observe(generationKey);

    uint256 unit = source.oneCollateral;
    uint256 depositAssets = 500 * unit;
    collateral.mint(_LP, depositAssets);
    _VM.startPrank(_LP);
    collateral.approve(address(vault), type(uint256).max);
    uint256 lpShares = vault.deposit(depositAssets, _LP);
    _VM.stopPrank();

    collateral.mint(address(pool), 1_000 * unit);
    outcome.mint(address(pool), source.yesId, 1_000 * unit);
    outcome.mint(_TRADER, source.yesId, 20 * unit);
    collateral.mint(_TRADER, 200 * unit);
    _VM.startPrank(_TRADER);
    outcome.approve(address(controller), source.yesId, type(uint256).max);
    collateral.approve(address(controller), type(uint256).max);
    (uint256 positionId,,) = controller.openPosition(
      IDreamMarginController.OpenParams({
        key: key,
        outcomeIndex: 0,
        initialShares: 20 * unit,
        leverageBps: 18_000,
        maxCollateralIn: 25 * unit,
        minSharesOut: unit,
        // The local model supplies a deterministic fill at the pinned conservative bid. The
        // deployed ask remains recorded in the snapshot, but is not claimed as a live fill.
        limitPrice: source.bestBid.price,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600
      })
    );
    uint256 firstRepayment = controller.repay(positionId, unit);
    require(firstRepayment != 0, "REPAYMENT_MISSING");
    controller.close(
      IDreamMarginController.CloseParams({
        positionId: positionId,
        maxRepayAssets: type(uint256).max,
        minCollateralOut: 0,
        limitPrice: source.bestBid.price,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600,
        withdrawOutcome: true
      })
    );
    _VM.stopPrank();

    Position memory closed = controller.getPosition(positionId);
    require(closed.status == PositionStatus.CLOSED, "POSITION_NOT_CLOSED");
    require(closed.shares == 0 && closed.debtShares == 0, "POSITION_NOT_ZERO");
    require(vault.totalDebtShares() == 0, "VAULT_DEBT_REMAINS");

    _VM.prank(_LP);
    uint256 withdrawn = vault.redeem(lpShares, _LP, _LP);
    require(withdrawn >= depositAssets, "LP_WITHDRAWAL_SHORT");
    require(vault.balanceOf(_LP) == 0, "LP_SHARES_REMAIN");

    result = ForkRehearsalResult({
      sourceFingerprint: source.sourceFingerprint,
      generationKey: generationKey,
      sourceModule: source.module,
      sourceMarket: source.market,
      sourcePool: source.pool,
      mirrorModule: address(module),
      mirrorMarket: address(market),
      mirrorPool: address(pool),
      collateral: address(collateral),
      outcomeToken: address(outcome),
      vault: address(vault),
      oracle: address(oracle),
      controller: address(controller),
      positionOpenFacet: address(positionOpen),
      positionCloseFacet: address(positionClose),
      positionLiquidationFacet: address(positionLiquidation),
      positionSettlementFacet: address(positionSettlement),
      positionId: positionId,
      lpAssetsDeposited: depositAssets,
      lpAssetsWithdrawn: withdrawn
    });
  }

  /// @notice Mirrors pinned prices while supplying deterministic local depth.
  /// @param pool Local pool receiving the levels.
  /// @param source Pinned price and collateral-unit inputs.
  function _seedBook(MockDreamDexBinaryPool pool, ShannonSnapshot memory source) private {
    uint256 depth = 1_000 * source.oneCollateral;
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: source.bestBid.price, quantity: depth});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: source.bestAsk.price, quantity: depth});
    pool.setBookLevels(true, bids);
    pool.setBookLevels(false, asks);
  }

  /// @notice Returns four deliberately separated administrative accounts.
  /// @return roles Initial role assignments.
  function _roles() private pure returns (DreamMarginController.InitialRoles memory roles) {
    roles = DreamMarginController.InitialRoles({
      governance: _GOVERNANCE,
      riskSteward: _RISK_STEWARD,
      guardian: _GUARDIAN,
      feeCollector: _FEE_COLLECTOR
    });
  }

  /// @notice Returns bounded local-only global risk values.
  /// @param unit One whole collateral token.
  /// @return config Global rehearsal policy.
  function _globalRisk(uint256 unit) private pure returns (GlobalRiskConfig memory config) {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * unit,
      maxDailyRealizedLoss: 100 * unit,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: _GOVERNANCE_DELAY,
      lossWindow: 1 days,
      lossCooldown: 2 days
    });
  }

  /// @notice Returns a conservative local-only generation policy.
  /// @param key Mirrored generation tuple.
  /// @param unit One whole collateral token.
  /// @return config Generation rehearsal policy.
  function _generation(MarketKey memory key, uint256 unit)
    private
    pure
    returns (GenerationConfig memory config)
  {
    config = GenerationConfig({
      key: key,
      risk: RiskConfig({
        maxDebtPerPosition: 100 * unit,
        maxDebtPerOutcome: 300 * unit,
        maxDebtPerMarket: 700 * unit,
        minDebt: unit,
        initialLtvBps: 6_000,
        maintenanceLtvBps: 7_500,
        collateralFactorBps: 8_000,
        liquidationBonusBps: 500,
        maxSpreadBps: 1_000,
        maxSlippageBps: 1_000,
        maxPositionDepthBps: 5_000,
        maxLeverageBps: 20_000,
        openingCutoff: 1_200,
        reduceOnlyCutoff: 600,
        compressionWindow: 3_600,
        maxBookLevels: 4,
        collateralDecimals: 6,
        outcomeIndex: 0
      }),
      marketGroup: _MARKET_GROUP,
      enabled: true,
      frozen: false
    });
  }

  /// @notice Returns a short-window oracle policy suitable only for deterministic rehearsal.
  /// @param key Mirrored generation tuple.
  /// @param unit One whole outcome quantity.
  /// @return config Local observation policy.
  function _oracleConfig(MarketKey memory key, uint256 unit)
    private
    pure
    returns (OracleConfig memory config)
  {
    config = OracleConfig({
      key: key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: uint128(100 * unit),
      maxObservations: 8,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Verifies every immutable binding and separated initial role.
  /// @param controller Deployed DreamMargin facade.
  /// @param vault Deployed collateral vault.
  /// @param oracle Deployed mark oracle.
  /// @param module Local DreamDEX module mirror.
  function _assertBindings(
    DreamMarginController controller,
    DreamMarginVault vault,
    DreamDexMarkOracle oracle,
    MockDreamDexBinaryModule module
  ) private view {
    require(controller.module() == address(module), "MODULE_BINDING");
    require(controller.vault() == address(vault), "VAULT_BINDING");
    require(controller.oracle() == address(oracle), "ORACLE_BINDING");
    require(vault.controller() == address(controller), "VAULT_CONTROLLER");
    require(oracle.configurator() == address(controller), "ORACLE_CONFIGURATOR");
    require(
      controller.rolesOf(_GOVERNANCE) == LibDreamMarginConstants.ROLE_GOVERNANCE, "GOVERNANCE_ROLE"
    );
    require(
      controller.rolesOf(_RISK_STEWARD) == LibDreamMarginConstants.ROLE_RISK_STEWARD, "RISK_ROLE"
    );
    require(controller.rolesOf(_GUARDIAN) == LibDreamMarginConstants.ROLE_GUARDIAN, "GUARDIAN_ROLE");
    require(
      controller.rolesOf(_FEE_COLLECTOR) == LibDreamMarginConstants.ROLE_FEE_COLLECTOR, "FEE_ROLE"
    );
  }
}

// forge-lint: disable-end(unsafe-cheatcode, unsafe-typecast, unused-return, block-timestamp, incorrect-strict-equality)
