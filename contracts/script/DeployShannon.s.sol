// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon deployment
/// @author DreamMargin contributors
/// @notice Deploys the immutable DreamMargin stack and writes its machine-readable manifest.
/// @dev The script predicts the controller CREATE address because the vault and oracle bind it
///      before the controller is deployed. Do not send another transaction from the deployer
///      concurrently with this script.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {PositionSettlement} from "src/dreammargin/base/PositionSettlement.sol";
import {DreamMarginReentrancyGuard} from "src/libs/dreammargin/DreamMarginReentrancyGuard.sol";
import {GlobalRiskConfig} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {Script} from "forge-std/Script.sol";

// Script serialization and checked configuration casts are deliberate.
// forge-lint: disable-start(block-timestamp, unsafe-typecast, unused-return)

/// @notice Minimal stateful probe proving Shannon executes transient-storage reentrancy guards.
contract ShannonTransientProbe is DreamMarginReentrancyGuard {
  /// @notice Enters and exits the same Solady transient guard used by DreamMargin.
  /// @return marker Deterministic success marker.
  function probe() external nonReentrant returns (bytes4 marker) {
    marker = this.probe.selector;
  }
}

/// @notice Broadcasts the core deployment from the PRIVATE_KEY environment variable.
contract DeployShannon is Script {
  string private constant _OUTPUT = "deployments/shannon-deployment.json";
  uint256 private constant _ANNUAL_RATE_WAD = 0.05e18;

  /// @notice Deploys, validates, and serializes the complete Shannon stack.
  /// @return deployment Addresses and testnet governance delay written to the manifest.
  function run() external returns (LibShannonSetup.Deployment memory deployment) {
    require(block.chainid == LibShannonSetup.CHAIN_ID, "WRONG_CHAIN");
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);
    uint256 delayValue = vm.envOr("GOVERNANCE_DELAY_SECONDS", uint256(60));
    require(delayValue != 0 && delayValue <= 1 hours, "INVALID_DEMO_DELAY");
    uint40 governanceDelay = uint40(delayValue);
    GlobalRiskConfig memory globalRisk = LibShannonSetup.globalRisk(governanceDelay);
    DreamMarginController.InitialRoles memory roles = DreamMarginController.InitialRoles({
      governance: deployer, riskSteward: deployer, guardian: deployer, feeCollector: deployer
    });

    uint256 startingNonce = vm.getNonce(deployer);
    address predictedController = vm.computeCreateAddress(deployer, startingNonce + 8);

    vm.startBroadcast(privateKey);
    ShannonTransientProbe transientProbe = new ShannonTransientProbe();
    require(
      transientProbe.probe() == transientProbe.probe.selector, "TRANSIENT_STORAGE_UNSUPPORTED"
    );
    PositionOpen positionOpen = new PositionOpen();
    PositionClose positionClose = new PositionClose();
    PositionLiquidation positionLiquidation = new PositionLiquidation();
    PositionSettlement positionSettlement = new PositionSettlement();
    DreamMarginVault vault =
      new DreamMarginVault(LibShannonSetup.TEST_USDC, predictedController, _ANNUAL_RATE_WAD);
    DreamDexMarkOracle oracle =
      new DreamDexMarkOracle(LibShannonSetup.DREAMDEX_MODULE, predictedController);
    DreamMarginController controller = new DreamMarginController(
      LibShannonSetup.DREAMDEX_MODULE,
      address(vault),
      address(oracle),
      deployer,
      address(positionOpen),
      address(positionClose),
      address(positionLiquidation),
      address(positionSettlement),
      roles,
      globalRisk
    );
    vm.stopBroadcast();

    require(address(controller) == predictedController, "CONTROLLER_ADDRESS_MISMATCH");
    deployment = LibShannonSetup.Deployment({
      deployer: deployer,
      transientProbe: address(transientProbe),
      positionOpen: address(positionOpen),
      positionClose: address(positionClose),
      positionLiquidation: address(positionLiquidation),
      positionSettlement: address(positionSettlement),
      vault: address(vault),
      oracle: address(oracle),
      controller: address(controller),
      governanceDelay: governanceDelay
    });
    LibShannonSetup.assertDeployment(deployment);
    require(controller.rolesOf(deployer) == 15, "ROLE_BITMAP");
    _writeManifest(deployment, roles, globalRisk, startingNonce);
  }

  /// @notice Serializes addresses, bytecode identities, and exact constructor arguments.
  /// @param deployment Deployed-stack addresses.
  /// @param roles Single-wallet testnet initial roles.
  /// @param globalRisk Testnet global policy.
  /// @param startingNonce Deployer nonce before the probe deployment.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    DreamMarginController.InitialRoles memory roles,
    GlobalRiskConfig memory globalRisk,
    uint256 startingNonce
  ) private {
    bytes memory vaultArgs = abi.encode(
      LibShannonSetup.TEST_USDC, deployment.controller, _ANNUAL_RATE_WAD
    );
    bytes memory oracleArgs = abi.encode(LibShannonSetup.DREAMDEX_MODULE, deployment.controller);
    bytes memory controllerArgs = abi.encode(
      LibShannonSetup.DREAMDEX_MODULE,
      deployment.vault,
      deployment.oracle,
      deployment.deployer,
      deployment.positionOpen,
      deployment.positionClose,
      deployment.positionLiquidation,
      deployment.positionSettlement,
      roles,
      globalRisk
    );

    string memory object = "dreammargin-shannon-deployment";
    vm.serializeString(object, "schema", "dreammargin.shannon-deployment.v1");
    vm.serializeString(object, "network", "somnia-shannon");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "deployedAtBlock", block.number);
    vm.serializeUint(object, "deployerStartingNonce", startingNonce);
    vm.serializeBool(object, "testnetOnly", true);
    vm.serializeBool(object, "productionReady", false);
    vm.serializeBool(object, "singleWalletRoles", true);
    vm.serializeBool(object, "secretExcluded", true);
    vm.serializeString(object, "solcVersion", "0.8.34");
    vm.serializeString(object, "evmVersion", "prague");
    vm.serializeUint(object, "optimizerRuns", 200);
    vm.serializeBool(object, "viaIr", true);
    vm.serializeAddress(object, "deployer", deployment.deployer);
    vm.serializeAddress(object, "governance", deployment.deployer);
    vm.serializeAddress(object, "riskSteward", deployment.deployer);
    vm.serializeAddress(object, "guardian", deployment.deployer);
    vm.serializeAddress(object, "feeCollector", deployment.deployer);
    vm.serializeAddress(object, "feeRecipient", deployment.deployer);
    vm.serializeAddress(object, "dreamDexModule", LibShannonSetup.DREAMDEX_MODULE);
    vm.serializeAddress(object, "collateral", LibShannonSetup.TEST_USDC);
    vm.serializeAddress(object, "outcomeToken", LibShannonSetup.OUTCOME_TOKEN);
    vm.serializeAddress(object, "transientProbe", deployment.transientProbe);
    vm.serializeAddress(object, "positionOpenFacet", deployment.positionOpen);
    vm.serializeAddress(object, "positionCloseFacet", deployment.positionClose);
    vm.serializeAddress(object, "positionLiquidationFacet", deployment.positionLiquidation);
    vm.serializeAddress(object, "positionSettlementFacet", deployment.positionSettlement);
    vm.serializeAddress(object, "vault", deployment.vault);
    vm.serializeAddress(object, "oracle", deployment.oracle);
    vm.serializeAddress(object, "controller", deployment.controller);
    vm.serializeBytes32(object, "transientProbeCodehash", deployment.transientProbe.codehash);
    vm.serializeBytes32(object, "positionOpenCodehash", deployment.positionOpen.codehash);
    vm.serializeBytes32(object, "positionCloseCodehash", deployment.positionClose.codehash);
    vm.serializeBytes32(
      object, "positionLiquidationCodehash", deployment.positionLiquidation.codehash
    );
    vm.serializeBytes32(
      object, "positionSettlementCodehash", deployment.positionSettlement.codehash
    );
    vm.serializeBytes32(object, "vaultCodehash", deployment.vault.codehash);
    vm.serializeBytes32(object, "oracleCodehash", deployment.oracle.codehash);
    vm.serializeBytes32(object, "controllerCodehash", deployment.controller.codehash);
    vm.serializeUint(object, "annualRateWad", _ANNUAL_RATE_WAD);
    vm.serializeUint(object, "governanceDelaySeconds", deployment.governanceDelay);
    vm.serializeUint(object, "maxDebtGlobal", globalRisk.maxDebtGlobal);
    vm.serializeUint(object, "maxDailyRealizedLoss", globalRisk.maxDailyRealizedLoss);
    vm.serializeUint(object, "maxVaultUtilizationBps", globalRisk.maxVaultUtilizationBps);
    vm.serializeBytes(object, "vaultConstructorArgs", vaultArgs);
    vm.serializeBytes(object, "oracleConstructorArgs", oracleArgs);
    string memory json = vm.serializeBytes(object, "controllerConstructorArgs", controllerArgs);
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(block-timestamp, unsafe-typecast, unused-return)
