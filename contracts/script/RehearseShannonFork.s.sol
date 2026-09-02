// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon fork-profile rehearsal script
/// @author DreamMargin contributors
/// @notice Produces a machine-readable manifest after a pinned-source local deployment smoke test.
/// @dev This script never broadcasts, requires no private key, and labels every local mirror address.

import {
  DreamMarginForkRehearsal,
  ForkRehearsalResult
} from "test/fork/harness/DreamMarginForkRehearsal.sol";
import {ShannonSnapshot, ShannonSnapshotReader} from "test/fork/harness/ShannonSnapshot.sol";

import {Script} from "forge-std/Script.sol";

// Serialization accumulates one object; only the final call's returned JSON is written.
// forge-lint: disable-start(unused-return)

/// @notice Rehearses deployment locally and writes `deployments/shannon-fork-rehearsal.json`.
contract RehearseShannonFork is Script {
  string private constant _OUTPUT = "deployments/shannon-fork-rehearsal.json";

  /// @notice Reads the pinned venue, runs the smoke flow, and writes its manifest.
  /// @return result Rehearsal addresses and accounting results.
  function run() external returns (ForkRehearsalResult memory result) {
    ShannonSnapshot memory source = ShannonSnapshotReader.read(vm);
    DreamMarginForkRehearsal rehearsal = new DreamMarginForkRehearsal();
    result = rehearsal.run(source);

    string memory object = "dreammargin-fork-rehearsal";
    vm.serializeString(object, "schema", "dreammargin.shannon-fork-rehearsal.v1");
    vm.serializeString(object, "mode", "PINNED_READS_LOCAL_WRITE_MIRROR");
    vm.serializeBool(object, "broadcast", false);
    vm.serializeBool(object, "usesPrivateKey", false);
    vm.serializeBool(object, "usesFundedTestnetAccount", false);
    vm.serializeBool(object, "provesLiveDreamDexWrites", false);
    vm.serializeUint(object, "chainId", 50_312);
    vm.serializeUint(object, "pinnedBlock", source.pinnedBlock);
    vm.serializeBytes32(object, "sourceMarketId", source.marketId);
    vm.serializeUint(object, "sourceMarketNonce", source.marketNonce);
    vm.serializeUint(object, "sourceYesId", source.yesId);
    vm.serializeUint(object, "sourceNoId", source.noId);
    vm.serializeUint(object, "sourceExpiry", source.expiry);
    vm.serializeUint(object, "sourceOneCollateral", source.oneCollateral);
    vm.serializeUint(object, "sourceBestBid", source.bestBid.price);
    vm.serializeUint(object, "sourceBestAsk", source.bestAsk.price);
    vm.serializeUint(object, "sourceTickSize", source.grid.tickSize);
    vm.serializeUint(object, "sourceMinimumQuantity", source.grid.minQuantity);
    vm.serializeUint(object, "sourceLotSize", source.grid.lotSize);
    vm.serializeBytes32(object, "sourceFingerprint", result.sourceFingerprint);
    vm.serializeBytes32(object, "sourceModuleCodehash", source.moduleCodehash);
    vm.serializeBytes32(object, "sourcePoolCodehash", source.poolCodehash);
    vm.serializeBytes32(object, "mirrorGenerationKey", result.generationKey);
    vm.serializeAddress(object, "sourceModule", result.sourceModule);
    vm.serializeAddress(object, "sourceMarket", result.sourceMarket);
    vm.serializeAddress(object, "sourcePool", result.sourcePool);
    vm.serializeAddress(object, "mirrorModule", result.mirrorModule);
    vm.serializeAddress(object, "mirrorMarket", result.mirrorMarket);
    vm.serializeAddress(object, "mirrorPool", result.mirrorPool);
    vm.serializeAddress(object, "mockCollateral", result.collateral);
    vm.serializeAddress(object, "mockOutcomeToken", result.outcomeToken);
    vm.serializeAddress(object, "vault", result.vault);
    vm.serializeAddress(object, "oracle", result.oracle);
    vm.serializeAddress(object, "controller", result.controller);
    vm.serializeAddress(object, "governance", address(0x1001));
    vm.serializeAddress(object, "riskSteward", address(0x1002));
    vm.serializeAddress(object, "guardian", address(0x1003));
    vm.serializeAddress(object, "feeCollector", address(0x1004));
    vm.serializeAddress(object, "feeRecipient", address(0x1005));
    vm.serializeAddress(object, "positionOpenFacet", result.positionOpenFacet);
    vm.serializeAddress(object, "positionCloseFacet", result.positionCloseFacet);
    vm.serializeAddress(object, "positionLiquidationFacet", result.positionLiquidationFacet);
    vm.serializeAddress(object, "positionSettlementFacet", result.positionSettlementFacet);
    vm.serializeUint(object, "smokePositionId", result.positionId);
    vm.serializeUint(object, "lpAssetsDeposited", result.lpAssetsDeposited);
    vm.serializeUint(object, "lpAssetsWithdrawn", result.lpAssetsWithdrawn);
    vm.serializeUint(object, "governanceDelaySeconds", 1 days);
    vm.serializeUint(object, "configuredMaxLeverageBps", 20_000);
    vm.serializeUint(object, "exercisedLeverageBps", 18_000);
    vm.serializeString(object, "solcVersion", "0.8.34");
    vm.serializeString(object, "evmVersion", "prague");
    vm.serializeUint(object, "optimizerRuns", 200);
    vm.serializeBool(object, "viaIr", true);
    vm.serializeString(
      object,
      "readBoundary",
      "Real DreamDEX identity, code, grid, expiry, backing, and top-of-book at the pinned block"
    );
    vm.serializeString(
      object,
      "writeBoundary",
      "Local mintable collateral, ERC-6909, market, module, settlement, and pool models"
    );
    vm.serializeString(
      object, "smokeFlow", "deploy-bind-roles-register-observe-deposit-open-repay-close-withdraw"
    );
    vm.serializeString(
      object,
      "rehearsalCommand",
      "FOUNDRY_PROFILE=fork forge script script/RehearseShannonFork.s.sol:RehearseShannonFork -vv"
    );
    string memory json = vm.serializeString(
      object,
      "verificationCommand",
      "script/verify-shannon.sh (template only; local mirror addresses are not explorer-verifiable)"
    );
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(unused-return)
