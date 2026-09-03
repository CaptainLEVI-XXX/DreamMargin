// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon market configuration
/// @author DreamMargin contributors
/// @notice Schedules and executes exact BTC and ETH daily-generation registrations.
/// @dev Discovery pins market IDs before either governance transaction. Both phases rebuild and
///      validate the same complete generation payload from DreamDEX state.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";

import {OracleConfig, ObservationRing} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  LibDreamMarginStorage,
  MarketKey
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {Script} from "forge-std/Script.sol";

// Configuration casts are preceded by explicit bounds and manifests intentionally serialize calls.
// The four fixed-size loops deliberately perform independent, bounded governance calls.
// forge-lint: disable-start(unsafe-typecast, unused-return, calls-loop, require-revert-in-loop)

/// @notice Shared configuration reconstruction for both delayed-governance phases.
abstract contract ShannonMarketConfiguration is Script {
  bytes32 internal constant BTC_GROUP = keccak256("SHANNON_BTC_DAILY");
  bytes32 internal constant ETH_GROUP = keccak256("SHANNON_ETH_DAILY");

  /// @notice One exact outcome registration and its governance identity.
  /// @param generationKey Hash of the full immutable market-generation tuple.
  /// @param changeId Deterministic delayed-change identifier.
  /// @param generation Controller generation policy.
  /// @param oracle Oracle observation policy.
  struct Registration {
    bytes32 generationKey;
    bytes32 changeId;
    GenerationConfig generation;
    OracleConfig oracle;
  }

  /// @notice Validates the stack and reconstructs four exact registrations.
  /// @return privateKey Broadcast key loaded only inside Foundry.
  /// @return deployment Parsed deployed stack.
  /// @return btc Validated BTC daily market.
  /// @return eth Validated ETH daily market.
  /// @return registrations BTC YES, BTC NO, ETH YES, and ETH NO policies.
  function _configuration()
    internal
    view
    returns (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,
      LibShannonSetup.LiveMarket memory btc,
      LibShannonSetup.LiveMarket memory eth,
      Registration[4] memory registrations
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

    uint256 minAgeValue = vm.envOr("ORACLE_MIN_AGE_SECONDS", uint256(60));
    uint256 updateIntervalValue = vm.envOr("ORACLE_UPDATE_INTERVAL_SECONDS", uint256(30));
    uint256 staleAfterValue = vm.envOr("ORACLE_STALE_AFTER_SECONDS", uint256(600));
    require(minAgeValue <= type(uint40).max, "MIN_AGE_OVERFLOW");
    require(updateIntervalValue <= type(uint40).max, "UPDATE_INTERVAL_OVERFLOW");
    require(staleAfterValue <= type(uint40).max, "STALE_AFTER_OVERFLOW");
    require(updateIntervalValue != 0, "ZERO_UPDATE_INTERVAL");
    require(minAgeValue >= updateIntervalValue, "MIN_AGE_TOO_SHORT");
    require(staleAfterValue >= minAgeValue, "STALE_BEFORE_MATURE");

    uint40 minAge = uint40(minAgeValue);
    uint40 updateInterval = uint40(updateIntervalValue);
    uint40 staleAfter = uint40(staleAfterValue);
    registrations[0] = _registration(btc.yesKey, 0, BTC_GROUP, minAge, updateInterval, staleAfter);
    registrations[1] = _registration(btc.noKey, 1, BTC_GROUP, minAge, updateInterval, staleAfter);
    registrations[2] = _registration(eth.yesKey, 0, ETH_GROUP, minAge, updateInterval, staleAfter);
    registrations[3] = _registration(eth.noKey, 1, ETH_GROUP, minAge, updateInterval, staleAfter);
  }

  /// @notice Builds one deterministic registration.
  /// @param key Exact DreamDEX generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param marketGroup Shared daily-market debt group.
  /// @param minAge Minimum mature observation age.
  /// @param updateInterval Minimum interval between observations.
  /// @param staleAfter Maximum newest-observation age.
  /// @return registration Controller, oracle, and delayed-governance values.
  function _registration(
    MarketKey memory key,
    uint8 outcomeIndex,
    bytes32 marketGroup,
    uint40 minAge,
    uint40 updateInterval,
    uint40 staleAfter
  ) private pure returns (Registration memory registration) {
    registration.generationKey = LibDreamMarginStorage.generationKey(key);
    registration.changeId = LibShannonSetup.registrationChangeId(registration.generationKey);
    registration.generation = LibShannonSetup.generationConfig(key, outcomeIndex, marketGroup);
    registration.oracle = LibShannonSetup.oracleConfig(key, minAge, updateInterval, staleAfter);
  }

  /// @notice Requires one executed registration to match both subsystems exactly.
  /// @param deployment Deployed controller and oracle.
  /// @param registration Expected complete registration.
  function _assertRegistration(
    LibShannonSetup.Deployment memory deployment,
    Registration memory registration
  ) internal view {
    GenerationConfig memory generation = IDreamMarginController(deployment.controller)
      .getGeneration(registration.generationKey);
    (OracleConfig memory oracle, ObservationRing memory ring) =
      IDreamDexMarkOracle(deployment.oracle).generationState(registration.generationKey);
    require(generation.enabled && !generation.frozen, "GENERATION_NOT_ACTIVE");
    require(
      keccak256(abi.encode(generation)) == keccak256(abi.encode(registration.generation)),
      "GENERATION_POLICY"
    );
    require(
      keccak256(abi.encode(oracle)) == keccak256(abi.encode(registration.oracle)), "ORACLE_POLICY"
    );
    require(ring.cardinality == 0, "UNEXPECTED_OBSERVATIONS");
  }
}

/// @notice Commits the exact four-registration payloads to delayed governance.
contract ScheduleShannonMarkets is ShannonMarketConfiguration {
  /// @notice Schedules BTC and ETH daily YES/NO registrations.
  function run() external {
    (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,,,
      Registration[4] memory registrations
    ) = _configuration();
    IDreamMarginController controller = IDreamMarginController(deployment.controller);

    vm.startBroadcast(privateKey);
    for (uint256 i = 0; i < registrations.length; ++i) {
      Registration memory registration = registrations[i];
      controller.scheduleGenerationChange(
        registration.changeId,
        registration.generationKey,
        registration.generation,
        registration.oracle
      );
    }
    vm.stopBroadcast();
  }
}

/// @notice Executes the already committed registrations after their delay.
contract ExecuteShannonMarkets is ShannonMarketConfiguration {
  string private constant _OUTPUT = "deployments/shannon-market-configuration.json";

  /// @notice Registers and verifies BTC and ETH daily YES/NO generations.
  function run() external {
    (
      uint256 privateKey,
      LibShannonSetup.Deployment memory deployment,
      LibShannonSetup.LiveMarket memory btc,
      LibShannonSetup.LiveMarket memory eth,
      Registration[4] memory registrations
    ) = _configuration();
    IDreamMarginController controller = IDreamMarginController(deployment.controller);

    vm.startBroadcast(privateKey);
    for (uint256 i = 0; i < registrations.length; ++i) {
      Registration memory registration = registrations[i];
      controller.executeGenerationChange(
        registration.changeId,
        registration.generationKey,
        registration.generation,
        registration.oracle
      );
    }
    vm.stopBroadcast();

    for (uint256 i = 0; i < registrations.length; ++i) {
      _assertRegistration(deployment, registrations[i]);
    }
    _writeManifest(deployment, btc, eth, registrations);
  }

  /// @notice Writes the selected generations and exact registration identities.
  /// @param deployment Deployed stack.
  /// @param btc Selected BTC daily generation.
  /// @param eth Selected ETH daily generation.
  /// @param registrations Four executed outcome policies.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    LibShannonSetup.LiveMarket memory btc,
    LibShannonSetup.LiveMarket memory eth,
    Registration[4] memory registrations
  ) private {
    string memory object = "dreammargin-shannon-markets";
    vm.serializeString(object, "schema", "dreammargin.shannon-markets.v1");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "configuredAtBlock", block.number);
    vm.serializeAddress(object, "controller", deployment.controller);
    vm.serializeAddress(object, "oracle", deployment.oracle);
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
    vm.serializeBytes32(object, "btcYesGenerationKey", registrations[0].generationKey);
    vm.serializeBytes32(object, "btcNoGenerationKey", registrations[1].generationKey);
    vm.serializeBytes32(object, "ethYesGenerationKey", registrations[2].generationKey);
    vm.serializeBytes32(object, "ethNoGenerationKey", registrations[3].generationKey);
    vm.serializeBytes32(object, "btcYesChangeId", registrations[0].changeId);
    vm.serializeBytes32(object, "btcNoChangeId", registrations[1].changeId);
    vm.serializeBytes32(object, "ethYesChangeId", registrations[2].changeId);
    vm.serializeBytes32(object, "ethNoChangeId", registrations[3].changeId);
    vm.serializeUint(object, "oracleMinAgeSeconds", registrations[0].oracle.minAge);
    vm.serializeUint(object, "oracleUpdateIntervalSeconds", registrations[0].oracle.updateInterval);
    string memory json =
      vm.serializeUint(object, "oracleStaleAfterSeconds", registrations[0].oracle.staleAfter);
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(unsafe-typecast, unused-return, calls-loop, require-revert-in-loop)
