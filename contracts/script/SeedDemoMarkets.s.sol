// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin long-lived demo-market seeder
/// @author DreamMargin contributors
/// @notice Funds the Shannon vault and places durable two-sided BTC and ETH demo liquidity.
/// @dev The demo account owns this static testnet inventory. Orders expire with their market;
///      no off-chain market-making or keeper process is required for the initial integration.

import {LibShannonSetup} from "script/LibShannonSetup.sol";

import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {Script} from "forge-std/Script.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// The script intentionally validates the live expiry before placing persistent demo orders.
// forge-lint: disable-start(block-timestamp, unused-return)

/// @notice Broadcasts the one-time liquidity setup for the dedicated DreamMargin markets.
contract SeedDemoMarkets is Script {
  using SafeTransferLib for address;

  string private constant _MARKETS = "deployments/shannon-demo-markets.json";
  string private constant _OUTPUT = "deployments/shannon-demo-liquidity.json";
  uint256 private constant _MINIMUM_INTERVAL = 31 days;
  uint256 private constant _MINIMUM_HEADROOM = 31 days;
  uint256 private constant _VAULT_TARGET = 500 * LibShannonSetup.UNIT;
  uint256 private constant _BOOK_QUANTITY = 200 * LibShannonSetup.UNIT;
  uint256 private constant _YES_BID = 450_000;
  uint256 private constant _YES_ASK = 550_000;
  uint8 private constant _SELL_YES = 1;
  uint8 private constant _SELL_NO = 3;
  uint8 private constant _LIMIT_ORDER = 0;

  /// @notice One market's durable seed-order identifiers.
  /// @param yesAskOrderId Resting SELL_YES order identifier.
  /// @param yesBidOrderId Resting SELL_NO order identifier represented in YES terms.
  struct SeedResult {
    uint128 yesAskOrderId;
    uint128 yesBidOrderId;
  }

  /// @notice Funds the vault, seeds both books, validates depth, and writes the manifest.
  function run() external {
    require(block.chainid == LibShannonSetup.CHAIN_ID, "WRONG_CHAIN");
    uint256 privateKey = vm.envUint("PRIVATE_KEY");
    address deployer = vm.addr(privateKey);
    LibShannonSetup.Deployment memory deployment = LibShannonSetup.readDeployment(vm);
    require(deployer == deployment.deployer, "WRONG_DEPLOYER");
    LibShannonSetup.assertDeployment(deployment);

    string memory json = vm.readFile(_MARKETS);
    bytes32 venueId = vm.parseJsonBytes32(json, ".venueId");
    LibShannonSetup.LiveMarket memory btc = LibShannonSetup.loadSeriesMarket(
      vm.parseJsonBytes32(json, ".btcMarketId"),
      venueId,
      _MINIMUM_HEADROOM,
      _MINIMUM_INTERVAL,
      false
    );
    LibShannonSetup.LiveMarket memory eth = LibShannonSetup.loadSeriesMarket(
      vm.parseJsonBytes32(json, ".ethMarketId"),
      venueId,
      _MINIMUM_HEADROOM,
      _MINIMUM_INTERVAL,
      false
    );

    vm.startBroadcast(privateKey);
    uint256 depositedAssets = _fundVault(deployment.vault, deployer);
    SeedResult memory btcSeed = _seed(btc, deployer);
    SeedResult memory ethSeed = _seed(eth, deployer);
    vm.stopBroadcast();

    btc = LibShannonSetup.loadSeriesMarket(
      btc.marketId, venueId, _MINIMUM_HEADROOM, _MINIMUM_INTERVAL, true
    );
    eth = LibShannonSetup.loadSeriesMarket(
      eth.marketId, venueId, _MINIMUM_HEADROOM, _MINIMUM_INTERVAL, true
    );
    _writeManifest(deployment, btc, eth, btcSeed, ethSeed, depositedAssets);
  }

  /// @notice Raises immediately available ERC-4626 assets to the configured demo target.
  /// @param vaultAddress Deployed DreamMargin vault.
  /// @param receiver Account receiving any newly minted vault shares.
  /// @return depositedAssets Assets added by this execution, in raw six-decimal tUSDC.
  function _fundVault(address vaultAddress, address receiver)
    private
    returns (uint256 depositedAssets)
  {
    IDreamMarginVault vault = IDreamMarginVault(vaultAddress);
    uint256 currentAssets = vault.totalAssets();
    if (currentAssets >= _VAULT_TARGET) return 0;
    depositedAssets = _VAULT_TARGET - currentAssets;
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(vaultAddress, depositedAssets);
    require(vault.deposit(depositedAssets, receiver) != 0, "EMPTY_VAULT_DEPOSIT");
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(vaultAddress, 0);
  }

  /// @notice Mints complete sets and places a 0.45 bid and 0.55 ask on one empty YES book.
  /// @param live Validated long-lived DreamDEX generation.
  /// @param owner Account funding the inventory and owning the resting orders.
  /// @return result Pool-scoped order identifiers, or zeros when the book was already seeded.
  function _seed(LibShannonSetup.LiveMarket memory live, address owner)
    private
    returns (SeedResult memory result)
  {
    IDreamDexBinaryPool pool = IDreamDexBinaryPool(live.pool);
    IDreamDexBinaryPool.BookLevel[] memory bids = pool.getBookLevels(true, 1);
    IDreamDexBinaryPool.BookLevel[] memory asks = pool.getBookLevels(false, 1);
    if (bids.length != 0 || asks.length != 0) {
      require(bids.length == 1 && asks.length == 1, "PARTIAL_BOOK");
      return result;
    }

    LibShannonSetup.TEST_USDC.safeApproveWithRetry(live.pool, _BOOK_QUANTITY);
    pool.mintSet(owner, owner, _BOOK_QUANTITY);
    LibShannonSetup.TEST_USDC.safeApproveWithRetry(live.pool, 0);

    IERC6909 outcome = IERC6909(live.yesKey.outcomeToken);
    require(outcome.approve(live.pool, live.yesKey.outcomeId, _BOOK_QUANTITY), "YES_APPROVAL");
    require(outcome.approve(live.pool, live.noKey.outcomeId, _BOOK_QUANTITY), "NO_APPROVAL");
    uint64 expiryNs = pool.marketExpiryNs();
    (bool askAccepted, uint128 askId) = pool.placeBinaryOrder(
      _SELL_YES, _YES_ASK, _BOOK_QUANTITY, expiryNs, _LIMIT_ORDER, 0, address(0), 0, 0
    );
    (bool bidAccepted, uint128 bidId) = pool.placeBinaryOrder(
      _SELL_NO, _YES_BID, _BOOK_QUANTITY, expiryNs, _LIMIT_ORDER, 0, address(0), 0, 0
    );
    require(askAccepted && bidAccepted, "ORDER_REJECTED");
    require(askId != 0 && bidId != 0, "ORDER_ID");
    result = SeedResult({yesAskOrderId: askId, yesBidOrderId: bidId});
  }

  /// @notice Writes the exact frontend liquidity and generation bindings.
  /// @param deployment Current DreamMargin deployment.
  /// @param btc Validated BTC demo market.
  /// @param eth Validated ETH demo market.
  /// @param btcSeed BTC seed order identifiers.
  /// @param ethSeed ETH seed order identifiers.
  /// @param depositedAssets Assets newly added to the vault.
  function _writeManifest(
    LibShannonSetup.Deployment memory deployment,
    LibShannonSetup.LiveMarket memory btc,
    LibShannonSetup.LiveMarket memory eth,
    SeedResult memory btcSeed,
    SeedResult memory ethSeed,
    uint256 depositedAssets
  ) private {
    string memory object = "dreammargin-shannon-demo-liquidity";
    vm.serializeString(object, "schema", "dreammargin.shannon-demo-liquidity.v1");
    vm.serializeUint(object, "chainId", LibShannonSetup.CHAIN_ID);
    vm.serializeUint(object, "seededAtBlock", block.number);
    vm.serializeAddress(object, "account", deployment.deployer);
    vm.serializeAddress(object, "vault", deployment.vault);
    vm.serializeUint(object, "vaultAssets", IDreamMarginVault(deployment.vault).totalAssets());
    vm.serializeUint(object, "depositedAssets", depositedAssets);
    vm.serializeBytes32(object, "btcMarketId", btc.marketId);
    vm.serializeAddress(object, "btcPool", btc.pool);
    vm.serializeUint(object, "btcYesId", btc.yesKey.outcomeId);
    vm.serializeUint(object, "btcNoId", btc.noKey.outcomeId);
    vm.serializeUint(object, "btcExpiry", btc.expiry);
    vm.serializeUint(object, "btcBestBid", btc.bestBid.price);
    vm.serializeUint(object, "btcBestAsk", btc.bestAsk.price);
    vm.serializeUint(object, "btcBidDepth", btc.bestBid.quantity);
    vm.serializeUint(object, "btcAskDepth", btc.bestAsk.quantity);
    vm.serializeUint(object, "btcBidOrderId", btcSeed.yesBidOrderId);
    vm.serializeUint(object, "btcAskOrderId", btcSeed.yesAskOrderId);
    vm.serializeBytes32(object, "ethMarketId", eth.marketId);
    vm.serializeAddress(object, "ethPool", eth.pool);
    vm.serializeUint(object, "ethYesId", eth.yesKey.outcomeId);
    vm.serializeUint(object, "ethNoId", eth.noKey.outcomeId);
    vm.serializeUint(object, "ethExpiry", eth.expiry);
    vm.serializeUint(object, "ethBestBid", eth.bestBid.price);
    vm.serializeUint(object, "ethBestAsk", eth.bestAsk.price);
    vm.serializeUint(object, "ethBidDepth", eth.bestBid.quantity);
    vm.serializeUint(object, "ethAskDepth", eth.bestAsk.quantity);
    vm.serializeUint(object, "ethBidOrderId", ethSeed.yesBidOrderId);
    string memory output = vm.serializeUint(object, "ethAskOrderId", ethSeed.yesAskOrderId);
    vm.writeJson(output, _OUTPUT);
  }
}

// forge-lint: disable-end(block-timestamp, unused-return)
