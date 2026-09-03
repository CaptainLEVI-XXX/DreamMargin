// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin Shannon lifecycle smoke test
/// @author DreamMargin contributors
/// @notice Exercises live funding, leveraged opening, repayment, closing, and LP redemption.
/// @dev This testnet-only broadcast uses real DreamDEX daily pools and records actual position IDs.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {
  LibDreamMarginStorage,
  MarketKey,
  Position,
  PositionStatus
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {Script} from "forge-std/Script.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// Live testnet timestamps and script serialization are intentional.
// forge-lint: disable-start(block-timestamp, unused-return)

/// @notice Shannon faucet extension used only by the deployment smoke test.
interface IShannonTestUsdc is IERC20Minimal {
  /// @notice Mints test-only collateral to the caller.
  /// @param amount Raw six-decimal tUSDC amount, capped by the faucet contract.
  function faucet(uint256 amount) external;
}

/// @notice Broadcasts one complete lifecycle on each selected underlying daily market.
contract SmokeShannon is Script {
  using SafeTransferLib for address;

  string private constant _OUTPUT = "deployments/shannon-smoke.json";
  uint256 private constant _FAUCET_TARGET = 1_000 * LibShannonSetup.UNIT;
  uint256 private constant _VAULT_DEPOSIT = 500 * LibShannonSetup.UNIT;
  uint256 private constant _SET_AMOUNT = 25 * LibShannonSetup.UNIT;
  uint256 private constant _INITIAL_SHARES = 16 * LibShannonSetup.UNIT;
  uint256 private constant _PARTIAL_REPAY = LibShannonSetup.UNIT / 4;
  uint32 private constant _LEVERAGE_BPS = 12_500;

  /// @notice One live position result retained for manifest output.
  /// @param positionId DreamMargin position identifier.
  /// @param generationKey Exact selected outcome generation.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param sharesBought Actual additional outcome shares purchased with vault credit.
  /// @param debtAssets Debt recorded immediately after opening.
  /// @param repaidAssets Actual partial repayment received by the vault.
  struct SmokeResult {
    uint256 positionId;
    bytes32 generationKey;
    uint8 outcomeIndex;
    uint256 sharesBought;
    uint256 debtAssets;
    uint256 repaidAssets;
  }

  /// @notice Funds, trades, closes, redeems, validates, and serializes the live flow.
  function run() external {
    require(block.chainid == LibShannonSetup.CHAIN_ID, "WRONG_CHAIN");
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);
    LibShannonSetup.Deployment memory deployment = LibShannonSetup.readDeployment(vm);
    require(deployer == deployment.deployer, "WRONG_DEPLOYER");
    LibShannonSetup.assertDeployment(deployment);

    (bytes32 btcMarketId, bytes32 ethMarketId) = LibShannonSetup.readSelectedMarketIds(vm);
    bytes32 venueId = vm.envBytes32("DREAMDEX_VENUE_ID");
    LibShannonSetup.LiveMarket memory btc =
      LibShannonSetup.loadLiveMarket(btcMarketId, venueId, 30 minutes);
    LibShannonSetup.LiveMarket memory eth =
      LibShannonSetup.loadLiveMarket(ethMarketId, venueId, 30 minutes);

    IDreamMarginVault vault = IDreamMarginVault(deployment.vault);
    IDreamMarginController controller = IDreamMarginController(deployment.controller);
    uint256 balance = IERC20Minimal(LibShannonSetup.TEST_USDC).balanceOf(deployer);

    vm.startBroadcast(privateKey);
    if (balance < _FAUCET_TARGET) {
      IShannonTestUsdc(LibShannonSetup.TEST_USDC).faucet(_FAUCET_TARGET - balance);
    }
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(deployment.vault, _VAULT_DEPOSIT);
    uint256 vaultShares = vault.deposit(_VAULT_DEPOSIT, deployer);
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(deployment.vault, 0);
    _mintSet(btc.pool, deployer);
    _mintSet(eth.pool, deployer);
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(deployment.controller, type(uint256).max);
    SmokeResult memory btcResult = _exerciseMarket(deployment, btc, deployer);
    SmokeResult memory ethResult = _exerciseMarket(deployment, eth, deployer);
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(deployment.controller, 0);
    uint256 redeemedAssets = vault.redeem(vaultShares, deployer, deployer);
    vm.stopBroadcast();

    require(redeemedAssets >= _VAULT_DEPOSIT, "INCOMPLETE_VAULT_EXIT");
    require(vault.totalDebtShares() == 0, "OUTSTANDING_VAULT_DEBT");
    _assertClosed(controller, btcResult.positionId, deployer);
    _assertClosed(controller, ethResult.positionId, deployer);
    _writeManifest(deployment, btcResult, ethResult, vaultShares, redeemedAssets);
  }

  /// @notice Converts test collateral into one complete outcome set on a live pool.
  /// @param pool Current DreamDEX pool.
  /// @param receiver Account receiving both outcome IDs.
  function _mintSet(address pool, address receiver) private {
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(pool, _SET_AMOUNT);
    IDreamDexBinaryPool(pool).mintSet(receiver, receiver, _SET_AMOUNT);
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(pool, 0);
  }

  /// @notice Selects the stronger conservative side and completes its leverage lifecycle.
  /// @param deployment Deployed stack.
  /// @param live Validated underlying DreamDEX daily market.
  /// @param owner Position owner.
  /// @return result Actual position and accounting values.
  function _exerciseMarket(
    LibShannonSetup.Deployment memory deployment,
    LibShannonSetup.LiveMarket memory live,
    address owner
  ) private returns (SmokeResult memory result) {
    IDreamDexMarkOracle oracle = IDreamDexMarkOracle(deployment.oracle);
    bytes32 yesGeneration = LibDreamMarginStorage.generationKey(live.yesKey);
    bytes32 noGeneration = LibDreamMarginStorage.generationKey(live.noKey);
    (uint256 yesMark,,) = oracle.conservativeTwap(yesGeneration);
    (uint256 noMark,,) = oracle.conservativeTwap(noGeneration);
    bool useYes = yesMark >= noMark;
    MarketKey memory key = useYes ? live.yesKey : live.noKey;
    result.generationKey = useYes ? yesGeneration : noGeneration;
    result.outcomeIndex = useYes ? 0 : 1;

    IERC6909 outcome = IERC6909(key.outcomeToken);
    require(outcome.balanceOf(owner, key.outcomeId) >= _INITIAL_SHARES, "OUTCOME_FUNDING");
    require(
      outcome.approve(deployment.controller, key.outcomeId, _INITIAL_SHARES), "OUTCOME_APPROVAL"
    );

    uint256 limitPrice = useYes ? live.bestAsk.price : live.bestBid.price;
    IDreamMarginController.OpenParams memory params = IDreamMarginController.OpenParams({
      key: key,
      outcomeIndex: result.outcomeIndex,
      initialShares: _INITIAL_SHARES,
      leverageBps: _LEVERAGE_BPS,
      maxCollateralIn: 10 * LibShannonSetup.UNIT,
      minSharesOut: live.book.lotSize,
      limitPrice: limitPrice,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 2 minutes
    });
    (result.positionId, result.sharesBought, result.debtAssets) =
      IDreamMarginController(deployment.controller).openPosition(params);
    require(result.sharesBought != 0 && result.debtAssets > _PARTIAL_REPAY, "EMPTY_OPEN");

    result.repaidAssets =
      IDreamMarginController(deployment.controller).repay(result.positionId, _PARTIAL_REPAY);
    require(result.repaidAssets != 0, "EMPTY_REPAY");
    IDreamMarginController(deployment.controller)
      .close(
        IDreamMarginController.CloseParams({
          positionId: result.positionId,
          maxRepayAssets: 10 * LibShannonSetup.UNIT,
          minCollateralOut: 0,
          limitPrice: 0,
          orderType: 0,
          deadline: 0,
          withdrawOutcome: true
        })
      );
  }

  /// @notice Verifies a terminal position has no attributed collateral or debt.
  /// @param controller Deployed controller.
  /// @param positionId Closed position ID.
  /// @param owner Expected owner.
  function _assertClosed(IDreamMarginController controller, uint256 positionId, address owner)
    private
    view
  {
    Position memory position = controller.getPosition(positionId);
    require(position.owner == owner, "POSITION_OWNER");
    require(position.status == PositionStatus.CLOSED, "POSITION_NOT_CLOSED");
    require(position.shares == 0 && position.debtShares == 0, "POSITION_NOT_EMPTY");
  }

  /// @notice Writes the actual lifecycle outputs and final debt-free state.
  /// @param deployment Deployed stack.
  /// @param btc BTC daily smoke result.
  /// @param eth ETH daily smoke result.
  /// @param vaultShares ERC-4626 shares minted and fully redeemed.
  /// @param redeemedAssets Assets returned by the synchronous LP exit.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    SmokeResult memory btc,
    SmokeResult memory eth,
    uint256 vaultShares,
    uint256 redeemedAssets
  ) private {
    string memory object = "dreammargin-shannon-smoke";
    vm.serializeString(object, "schema", "dreammargin.shannon-smoke.v1");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "completedAtBlock", block.number);
    vm.serializeAddress(object, "account", deployment.deployer);
    vm.serializeAddress(object, "controller", deployment.controller);
    vm.serializeAddress(object, "vault", deployment.vault);
    vm.serializeUint(object, "btcPositionId", btc.positionId);
    vm.serializeBytes32(object, "btcGenerationKey", btc.generationKey);
    vm.serializeUint(object, "btcOutcomeIndex", btc.outcomeIndex);
    vm.serializeUint(object, "btcSharesBought", btc.sharesBought);
    vm.serializeUint(object, "btcOpeningDebtAssets", btc.debtAssets);
    vm.serializeUint(object, "btcPartialRepayAssets", btc.repaidAssets);
    vm.serializeUint(object, "ethPositionId", eth.positionId);
    vm.serializeBytes32(object, "ethGenerationKey", eth.generationKey);
    vm.serializeUint(object, "ethOutcomeIndex", eth.outcomeIndex);
    vm.serializeUint(object, "ethSharesBought", eth.sharesBought);
    vm.serializeUint(object, "ethOpeningDebtAssets", eth.debtAssets);
    vm.serializeUint(object, "ethPartialRepayAssets", eth.repaidAssets);
    vm.serializeUint(object, "vaultSharesRedeemed", vaultShares);
    vm.serializeUint(object, "vaultAssetsRedeemed", redeemedAssets);
    string memory json = vm.serializeUint(object, "finalVaultDebtShares", 0);
    vm.writeJson(json, _OUTPUT);
  }
}

// forge-lint: disable-end(block-timestamp, unused-return)
