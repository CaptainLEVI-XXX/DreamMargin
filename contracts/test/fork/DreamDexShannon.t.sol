// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX Shannon integration tests
/// @author DreamMargin contributors
/// @notice Pins the production interfaces to one live and one recycled DreamDEX generation.
/// @dev Raw historical RPC calls avoid relying on indexer state or unsupported fork RPC methods.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";

import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";
import {IDreamDexBinaryModule} from "src/interfaces/integrations/IDreamDexBinaryModule.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IDreamDexBinarySettlement} from "src/interfaces/integrations/IDreamDexBinarySettlement.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Verifies DreamMargin ABI decoding against deployed DreamDEX event contracts.
contract DreamDexShannonTest is Test {
  string private constant _BLOCK_TAG = "0x1c68e9b0";

  address private constant _MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;
  address private constant _SETTLEMENT = 0xbF4a49e0Dfd092e5FBE8E5761064C49533e6Ed23;
  address private constant _COLLATERAL = 0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E;
  address private constant _OUTCOME_TOKEN = 0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9;

  bytes32 private constant _PROXY_CODEHASH =
    0x096a0d8dbb41f8efd972a34a05774baf2c8120e7e397ce860c71f3667a9e90f3;
  bytes32 private constant _POOL_CODEHASH =
    0x2f738388465eb9c4fefb7836fe33f130b35c9c6ca25c6834bf676dceb005be4e;

  bytes32 private constant _LIVE_MARKET_ID = bytes32(uint256(0xfc5b));
  address private constant _LIVE_MARKET = 0x7c3b8d502D48F338af19A477929C47f07F4A7530;
  address private constant _LIVE_POOL = 0x3bF5a4385af0d4DFd2eb38713Ae21D9FC82c0542;
  uint64 private constant _LIVE_NONCE = 80;
  uint256 private constant _LIVE_YES_ID =
    1_616_505_921_066_909_234_947_634_033_314_385_211_062_152_992_443_827_836_608_737_674_547_200;

  bytes32 private constant _FINAL_MARKET_ID = bytes32(uint256(0xfc55));
  address private constant _FINAL_MARKET = 0xe66bf10a47327426814Be478d8C1E71dC054Ee08;
  address private constant _RECYCLED_POOL = 0xD48676D2Cd15F6C24F75c0358B205e54a3434Bc5;
  uint64 private constant _FINAL_NONCE = 449;
  uint256 private constant _FINAL_YES_ID =
    5_729_669_421_648_296_978_528_219_141_923_302_665_953_690_484_987_165_540_164_240_672_932_096;

  /// @notice Validates exact code, generation identity, economics, and book decoding.
  function test_liveGenerationMatchesPinnedDeployment() external {
    assertEq(keccak256(_rpcCode(_MODULE)), _PROXY_CODEHASH);
    assertEq(keccak256(_rpcCode(_SETTLEMENT)), _PROXY_CODEHASH);
    assertEq(keccak256(_rpcCode(_OUTCOME_TOKEN)), _PROXY_CODEHASH);
    assertEq(keccak256(_rpcCode(_LIVE_POOL)), _POOL_CODEHASH);

    address settlement = abi.decode(
      _rpcCall(_MODULE, abi.encodeCall(IDreamDexBinaryModule.settlement, ())), (address)
    );
    assertEq(settlement, _SETTLEMENT);
    uint64 nonce = abi.decode(
      _rpcCall(_MODULE, abi.encodeCall(IDreamDexBinaryModule.marketNonce, (_LIVE_MARKET_ID))),
      (uint64)
    );
    assertEq(nonce, _LIVE_NONCE);

    DreamDexAdapter.ModuleMarket memory record = abi.decode(
      _rpcCall(_MODULE, abi.encodeCall(IDreamDexBinaryModule.markets, (_LIVE_MARKET_ID))),
      (DreamDexAdapter.ModuleMarket)
    );
    assertEq(record.collateral, _COLLATERAL);
    assertEq(record.originOperatorId, 2);
    assertEq(
      record.originVenueId, 0x679795a0195a1b76cdebb7c51d74e058aee92919b8c3389af86ef24535e8a28c
    );
    assertEq(record.market, _LIVE_MARKET);
    assertEq(record.pool, _LIVE_POOL);
    assertEq(record.yesId, _LIVE_YES_ID);
    assertEq(record.noId, _LIVE_YES_ID + 1);
    assertEq(record.expiry, 1_788_237_000);

    IDreamDexBinaryPool.BinaryPoolInfo memory info = abi.decode(
      _rpcCall(_LIVE_POOL, abi.encodeCall(IDreamDexBinaryPool.getBinaryPoolParams, ())),
      (IDreamDexBinaryPool.BinaryPoolInfo)
    );
    assertEq(info.outcomeToken, _OUTCOME_TOKEN);
    assertEq(info.oneCollateral, 1e6);
    assertEq(info.setBacking, 1_500_000_000);
    assertEq(info.settlement, _SETTLEMENT);
    assertEq(info.marketNonce, _LIVE_NONCE);
    assertFalse(info.finalized);

    // The bools are the deployed ABI's explicit bid- and ask-side selectors.
    // forge-lint: disable-start(boolean-cst)
    IDreamDexBinaryPool.BookLevel[] memory bids = abi.decode(
      _rpcCall(_LIVE_POOL, abi.encodeCall(IDreamDexBinaryPool.getBookLevels, (true, 1))),
      (IDreamDexBinaryPool.BookLevel[])
    );
    IDreamDexBinaryPool.BookLevel[] memory asks = abi.decode(
      _rpcCall(_LIVE_POOL, abi.encodeCall(IDreamDexBinaryPool.getBookLevels, (false, 1))),
      (IDreamDexBinaryPool.BookLevel[])
    );
    // forge-lint: disable-end(boolean-cst)
    assertEq(bids[0].price, 897_000);
    assertEq(asks[0].price, 919_000);
    assertLt(bids[0].price, asks[0].price);
  }

  /// @notice Validates frozen settlement after the old pool has advanced to a new nonce.
  function test_finalizedGenerationSurvivesPoolRecycle() external {
    uint64 recordedNonce = abi.decode(
      _rpcCall(_MODULE, abi.encodeCall(IDreamDexBinaryModule.marketNonce, (_FINAL_MARKET_ID))),
      (uint64)
    );
    assertEq(recordedNonce, _FINAL_NONCE);

    IDreamDexBinaryPool.BinaryPoolInfo memory livePool = abi.decode(
      _rpcCall(_RECYCLED_POOL, abi.encodeCall(IDreamDexBinaryPool.getBinaryPoolParams, ())),
      (IDreamDexBinaryPool.BinaryPoolInfo)
    );
    assertEq(livePool.marketNonce, 450);

    DreamDexAdapter.ModuleMarket memory oldRecord = abi.decode(
      _rpcCall(_MODULE, abi.encodeCall(IDreamDexBinaryModule.markets, (_FINAL_MARKET_ID))),
      (DreamDexAdapter.ModuleMarket)
    );
    assertEq(oldRecord.market, _FINAL_MARKET);
    assertEq(oldRecord.pool, _RECYCLED_POOL);
    assertEq(oldRecord.yesId, _FINAL_YES_ID);

    uint8 status = abi.decode(
      _rpcCall(_FINAL_MARKET, abi.encodeCall(IDreamDexBinaryMarket.status, ())), (uint8)
    );
    assertEq(status, 4);
    bool finalized = abi.decode(
      _rpcCall(_SETTLEMENT, abi.encodeCall(IDreamDexBinarySettlement.isFinalized, (_FINAL_YES_ID))),
      (bool)
    );
    assertTrue(finalized);

    IDreamDexBinarySettlement.SettlementRecord memory terminal = abi.decode(
      _rpcCall(
        _SETTLEMENT, abi.encodeCall(IDreamDexBinarySettlement.getSettlement, (_FINAL_YES_ID >> 8))
      ),
      (IDreamDexBinarySettlement.SettlementRecord)
    );
    assertEq(terminal.collateralToken, _COLLATERAL);
    assertEq(terminal.backing, 1_500_000_000);
    assertTrue(terminal.finalized);
    assertFalse(terminal.voided);
    assertEq(terminal.pool, _RECYCLED_POOL);
    assertEq(terminal.nonce, _FINAL_NONCE);
    assertEq(terminal.payoutNumerators[0], 0);
    assertEq(terminal.payoutNumerators[1], 10_000_000);
  }

  /// @notice Reads deployed bytecode at the pinned block.
  /// @param account Contract address read.
  /// @return code Runtime bytecode.
  function _rpcCode(address account) private returns (bytes memory code) {
    string memory params = string.concat("[\"", vm.toString(account), "\",\"", _BLOCK_TAG, "\"]");
    code = vm.rpc("somnia_testnet", "eth_getCode", params);
  }

  /// @notice Executes a historical read-only call against Shannon.
  /// @param target Contract called.
  /// @param callData ABI-encoded selector and arguments.
  /// @return result ABI-encoded return data.
  function _rpcCall(address target, bytes memory callData) private returns (bytes memory result) {
    string memory params = string.concat(
      "[{\"to\":\"",
      vm.toString(target),
      "\",\"data\":\"",
      vm.toString(callData),
      "\"},\"",
      _BLOCK_TAG,
      "\"]"
    );
    result = vm.rpc("somnia_testnet", "eth_call", params);
  }
}
