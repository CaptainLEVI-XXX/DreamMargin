// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon oracle observation
/// @author DreamMargin contributors
/// @notice Records one permissionless live-book sample for every configured daily outcome.
/// @dev Run twice with at least ORACLE_MIN_AGE_SECONDS between calls before opening positions.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";

import {
  MarkObservation,
  ObservationRing
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {LibDreamMarginStorage} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {Script} from "forge-std/Script.sol";

// Observation timestamps and manifest serialization are deliberate script behavior.
// The fixed four-generation loops deliberately call and validate each independent oracle ring.
// forge-lint: disable-start(block-timestamp, unused-return, calls-loop, require-revert-in-loop)

/// @notice Broadcasts one observation round from the configured testnet wallet.
contract ObserveShannon is Script {
  string private constant _OUTPUT = "deployments/shannon-oracle-observation.json";

  /// @notice Samples BTC YES/NO and ETH YES/NO, then records ring cardinalities.
  function run() external {
    require(block.chainid == LibShannonSetup.CHAIN_ID, "WRONG_CHAIN");
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    LibShannonSetup.Deployment memory deployment = LibShannonSetup.readDeployment(vm);
    require(vm.addr(privateKey) == deployment.deployer, "WRONG_DEPLOYER");
    LibShannonSetup.assertDeployment(deployment);

    (bytes32 btcMarketId, bytes32 ethMarketId) = LibShannonSetup.readSelectedMarketIds(vm);
    bytes32 venueId = vm.envBytes32("DREAMDEX_VENUE_ID");
    uint256 headroom = vm.envOr("MARKET_EXPIRY_HEADROOM_SECONDS", uint256(6 hours));
    LibShannonSetup.LiveMarket memory btc =
      LibShannonSetup.loadLiveMarket(btcMarketId, venueId, headroom);
    LibShannonSetup.LiveMarket memory eth =
      LibShannonSetup.loadLiveMarket(ethMarketId, venueId, headroom);
    bytes32[4] memory keys = [
      LibDreamMarginStorage.generationKey(btc.yesKey),
      LibDreamMarginStorage.generationKey(btc.noKey),
      LibDreamMarginStorage.generationKey(eth.yesKey),
      LibDreamMarginStorage.generationKey(eth.noKey)
    ];

    IDreamDexMarkOracle oracle = IDreamDexMarkOracle(deployment.oracle);
    vm.startBroadcast(privateKey);
    for (uint256 i = 0; i < keys.length; ++i) {
      MarkObservation memory observation = oracle.observe(keys[i]);
      require(observation.conservativeMark != 0, "ZERO_MARK");
    }
    vm.stopBroadcast();

    uint256[4] memory cardinalities;
    for (uint256 i = 0; i < keys.length; ++i) {
      (, ObservationRing memory ring) = oracle.generationState(keys[i]);
      require(ring.cardinality != 0, "EMPTY_RING");
      cardinalities[i] = ring.cardinality;
    }
    _writeManifest(deployment, keys, cardinalities);
  }

  /// @notice Writes the current observation state without exposing the signing key.
  /// @param deployment Deployed stack.
  /// @param keys Four registered generation keys.
  /// @param cardinalities Current observation counts.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    bytes32[4] memory keys,
    uint256[4] memory cardinalities
  ) private {
    string memory object = "dreammargin-shannon-observations";
    vm.serializeString(object, "schema", "dreammargin.shannon-observations.v1");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "observedAtBlock", block.number);
    vm.serializeUint(object, "observedAtTimestamp", block.timestamp);
    vm.serializeAddress(object, "oracle", deployment.oracle);
    vm.serializeBytes32(object, "btcYesGenerationKey", keys[0]);
    vm.serializeBytes32(object, "btcNoGenerationKey", keys[1]);
    vm.serializeBytes32(object, "ethYesGenerationKey", keys[2]);
    vm.serializeBytes32(object, "ethNoGenerationKey", keys[3]);
    vm.serializeUint(object, "btcYesCardinality", cardinalities[0]);
    vm.serializeUint(object, "btcNoCardinality", cardinalities[1]);
    vm.serializeUint(object, "ethYesCardinality", cardinalities[2]);
    string memory json = vm.serializeUint(object, "ethNoCardinality", cardinalities[3]);
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(block-timestamp, unused-return, calls-loop, require-revert-in-loop)
