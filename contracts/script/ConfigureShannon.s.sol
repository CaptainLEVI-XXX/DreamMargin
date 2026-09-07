// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon series configuration
/// @author DreamMargin contributors
/// @notice Registers one reusable DreamDEX-origin policy and activates current BTC/ETH outcomes.
/// @dev Governance approves the origin once; subsequent exact generations activate permissionlessly.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";

import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  MarketKey,
  SeriesOracleConfig,
  SeriesPolicy
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {Script} from "forge-std/Script.sol";

// Configuration casts are explicitly bounded and four activation calls are intentionally bounded.
// forge-lint: disable-start(unsafe-typecast, unused-return, calls-loop, require-revert-in-loop)

/// @notice Reconstructs the exact reusable policy and current outcome generations.
abstract contract ShannonSeriesConfiguration is Script {
  /// @notice Stable identifier for the trusted DreamDEX Shannon origin policy.
  bytes32 internal constant POLICY_ID = keccak256("SHANNON_DREAMDEX_ORIGIN_V1");

  /// @notice One exact current outcome that may activate under the reusable policy.
  /// @param generationKey Hash of the full immutable generation tuple.
  /// @param key Exact DreamDEX generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  struct Activation {
    bytes32 generationKey;
    MarketKey key;
    uint8 outcomeIndex;
  }

  /// @notice Loads live markets and reconstructs the single policy payload.
  /// @return privateKey Broadcast key loaded only inside Foundry.
  /// @return deployment Parsed deployed stack.
  /// @return btc Validated current BTC daily market.
  /// @return eth Validated current ETH daily market.
  /// @return changeId Deterministic delayed-policy change identifier.
  /// @return policy Reusable origin, risk, and oracle template.
  /// @return activations Current BTC/ETH YES/NO outcomes.
  function _configuration()
    internal
    view
    returns (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,
      LibShannonSetup.LiveMarket memory btc,
      LibShannonSetup.LiveMarket memory eth,
      bytes32 changeId,
      SeriesPolicy memory policy,
      Activation[4] memory activations
    )
  {
    require(block.chainid == LibShannonSetup.CHAIN_ID, "WRONG_CHAIN");
    privateKey = vm.envUint("PRIVATE_KEY");
    deployment = LibShannonSetup.readDeployment(vm);
    require(vm.addr(privateKey) == deployment.deployer, "WRONG_DEPLOYER");
    LibShannonSetup.assertDeployment(deployment);

    (bytes32 btcMarketId, bytes32 ethMarketId) = LibShannonSetup.readSelectedMarketIds(vm);
    bytes32 venueId = vm.envBytes32("DREAMDEX_VENUE_ID");
    uint256 headroom = vm.envOr("MARKET_EXPIRY_HEADROOM_SECONDS", uint256(6 hours));
    btc = LibShannonSetup.loadLiveMarket(btcMarketId, venueId, headroom);
    eth = LibShannonSetup.loadLiveMarket(ethMarketId, venueId, headroom);
    require(btc.creator == eth.creator, "CREATOR_MISMATCH");
    require(btc.originVenueId == eth.originVenueId, "VENUE_MISMATCH");
    require(btc.originOperatorId == eth.originOperatorId, "OPERATOR_MISMATCH");

    uint256 minAgeValue = vm.envOr("ORACLE_MIN_AGE_SECONDS", uint256(60));
    uint256 updateIntervalValue = vm.envOr("ORACLE_UPDATE_INTERVAL_SECONDS", uint256(30));
    uint256 staleAfterValue = vm.envOr("ORACLE_STALE_AFTER_SECONDS", uint256(600));
    uint256 minIntervalValue = vm.envOr("SERIES_MIN_INTERVAL_SECONDS", uint256(1 hours));
    require(minAgeValue <= type(uint40).max, "MIN_AGE_OVERFLOW");
    require(updateIntervalValue <= type(uint40).max, "UPDATE_INTERVAL_OVERFLOW");
    require(staleAfterValue <= type(uint40).max, "STALE_AFTER_OVERFLOW");
    require(minIntervalValue <= type(uint64).max, "MIN_INTERVAL_OVERFLOW");
    require(updateIntervalValue != 0 && minAgeValue >= updateIntervalValue, "ORACLE_TIMING");
    require(staleAfterValue >= minAgeValue, "STALE_BEFORE_MATURE");
    require(minIntervalValue > 1_200 + minAgeValue, "MIN_INTERVAL_TOO_SHORT");

    GenerationConfig memory generation =
      LibShannonSetup.generationConfig(btc.yesKey, 0, bytes32(uint256(1)));
    OracleConfig memory oracle = LibShannonSetup.oracleConfig(
      btc.yesKey, uint40(minAgeValue), uint40(updateIntervalValue), uint40(staleAfterValue)
    );
    policy = SeriesPolicy({
      creator: btc.creator,
      originVenueId: btc.originVenueId,
      originOperatorId: btc.originOperatorId,
      collateral: btc.yesKey.collateral,
      minIntervalSec: uint64(minIntervalValue),
      risk: generation.risk,
      oracle: SeriesOracleConfig({
        minAge: oracle.minAge,
        updateInterval: oracle.updateInterval,
        staleAfter: oracle.staleAfter,
        depthQuantity: oracle.depthQuantity,
        maxObservations: oracle.maxObservations,
        maxBookLevels: oracle.maxBookLevels
      }),
      enabled: true,
      frozen: false
    });
    changeId = keccak256(abi.encode("REGISTER_SHANNON_SERIES_POLICY_V1", POLICY_ID));
    activations[0] = _activation(btc.yesKey, 0);
    activations[1] = _activation(btc.noKey, 1);
    activations[2] = _activation(eth.yesKey, 0);
    activations[3] = _activation(eth.noKey, 1);
  }

  /// @notice Constructs one exact activation descriptor.
  /// @param key Current DreamDEX generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @return activation Derived activation descriptor.
  function _activation(MarketKey memory key, uint8 outcomeIndex)
    private
    pure
    returns (Activation memory activation)
  {
    activation = Activation({
      generationKey: LibDreamMarginStorage.generationKey(key), key: key, outcomeIndex: outcomeIndex
    });
  }

  /// @notice Verifies one activated controller/oracle outcome against its policy link.
  /// @param deployment Deployed controller and oracle addresses.
  /// @param activation Expected current outcome generation.
  function _assertActivation(
    LibShannonSetup.Deployment memory deployment,
    Activation memory activation
  ) internal view {
    IDreamMarginController controller = IDreamMarginController(deployment.controller);
    GenerationConfig memory generation = controller.getGeneration(activation.generationKey);
    (OracleConfig memory oracle,) =
      IDreamDexMarkOracle(deployment.oracle).generationState(activation.generationKey);
    require(generation.enabled && !generation.frozen, "GENERATION_NOT_ACTIVE");
    require(generation.risk.outcomeIndex == activation.outcomeIndex, "OUTCOME_INDEX");
    require(controller.policyForGeneration(activation.generationKey) == POLICY_ID, "POLICY_LINK");
    require(
      LibDreamMarginStorage.generationKey(oracle.key) == activation.generationKey, "ORACLE_KEY"
    );
  }
}

/// @notice Commits the reusable origin policy to delayed governance.
contract ScheduleShannonMarkets is ShannonSeriesConfiguration {
  /// @notice Schedules the single BTC/ETH origin policy.
  function run() external {
    (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,,,
      bytes32 changeId,
      SeriesPolicy memory policy,
    ) = _configuration();
    vm.startBroadcast(privateKey);
    IDreamMarginController(deployment.controller)
      .scheduleSeriesPolicyChange(changeId, POLICY_ID, policy);
    vm.stopBroadcast();
  }
}

/// @notice Executes the origin policy and permissionlessly activates current generations.
contract ExecuteShannonMarkets is ShannonSeriesConfiguration {
  string private constant _OUTPUT = "deployments/shannon-market-configuration.json";

  /// @notice Registers one policy, activates four outcomes, verifies them, and writes a manifest.
  function run() external {
    (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,
      LibShannonSetup.LiveMarket memory btc,
      LibShannonSetup.LiveMarket memory eth,
      bytes32 changeId,
      SeriesPolicy memory policy,
      Activation[4] memory activations
    ) = _configuration();
    IDreamMarginController controller = IDreamMarginController(deployment.controller);

    vm.startBroadcast(privateKey);
    controller.executeSeriesPolicyChange(changeId, POLICY_ID, policy);
    for (uint256 i = 0; i < activations.length; ++i) {
      controller.activateSeriesGeneration(activations[i].key, activations[i].outcomeIndex);
    }
    vm.stopBroadcast();

    for (uint256 i = 0; i < activations.length; ++i) {
      _assertActivation(deployment, activations[i]);
    }
    _writeManifest(deployment, btc, eth, changeId, policy, activations);
  }

  /// @notice Writes the reusable policy and current activated outcomes.
  /// @param deployment Deployed stack.
  /// @param btc Selected BTC daily generation.
  /// @param eth Selected ETH daily generation.
  /// @param changeId Executed delayed-policy identifier.
  /// @param policy Executed reusable policy.
  /// @param activations Four activated current outcomes.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    LibShannonSetup.LiveMarket memory btc,
    LibShannonSetup.LiveMarket memory eth,
    bytes32 changeId,
    SeriesPolicy memory policy,
    Activation[4] memory activations
  ) private {
    string memory object = "dreammargin-shannon-markets";
    vm.serializeString(object, "schema", "dreammargin.shannon-markets.v2");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "configuredAtBlock", block.number);
    vm.serializeAddress(object, "controller", deployment.controller);
    vm.serializeAddress(object, "oracle", deployment.oracle);
    vm.serializeBytes32(object, "policyId", POLICY_ID);
    vm.serializeBytes32(object, "policyChangeId", changeId);
    vm.serializeAddress(object, "creator", policy.creator);
    vm.serializeBytes32(object, "venueId", policy.originVenueId);
    vm.serializeUint(object, "operatorId", policy.originOperatorId);
    vm.serializeUint(object, "minimumIntervalSeconds", policy.minIntervalSec);
    vm.serializeBytes32(object, "btcMarketId", btc.marketId);
    vm.serializeAddress(object, "btcMarket", btc.market);
    vm.serializeAddress(object, "btcPool", btc.pool);
    vm.serializeUint(object, "btcNonce", btc.nonce);
    vm.serializeUint(object, "btcExpiry", btc.expiry);
    vm.serializeBytes32(object, "ethMarketId", eth.marketId);
    vm.serializeAddress(object, "ethMarket", eth.market);
    vm.serializeAddress(object, "ethPool", eth.pool);
    vm.serializeUint(object, "ethNonce", eth.nonce);
    vm.serializeUint(object, "ethExpiry", eth.expiry);
    vm.serializeBytes32(object, "btcYesGenerationKey", activations[0].generationKey);
    vm.serializeBytes32(object, "btcNoGenerationKey", activations[1].generationKey);
    vm.serializeBytes32(object, "ethYesGenerationKey", activations[2].generationKey);
    vm.serializeBytes32(object, "ethNoGenerationKey", activations[3].generationKey);
    vm.serializeUint(object, "oracleMinAgeSeconds", policy.oracle.minAge);
    vm.serializeUint(object, "oracleUpdateIntervalSeconds", policy.oracle.updateInterval);
    string memory json =
      vm.serializeUint(object, "oracleStaleAfterSeconds", policy.oracle.staleAfter);
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(unsafe-typecast, unused-return, calls-loop, require-revert-in-loop)
