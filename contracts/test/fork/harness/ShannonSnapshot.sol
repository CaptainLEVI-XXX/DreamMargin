// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Pinned DreamDEX Shannon snapshot
/// @author DreamMargin contributors
/// @notice Reads one real DreamDEX generation used to seed the local write-path rehearsal.
/// @dev The public Shannon RPC does not expose the methods Foundry needs for a state fork, so
///      historical `eth_call` and `eth_getCode` provide the immutable source-of-truth boundary.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";

import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";
import {IDreamDexBinaryModule} from "src/interfaces/integrations/IDreamDexBinaryModule.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {Vm} from "forge-std/Vm.sol";

/// @notice Read-only source data copied from a pinned deployed DreamDEX generation.
/// @param pinnedBlock Historical Shannon block used for every read.
/// @param marketId DreamDEX market identifier.
/// @param module Deployed DreamDEX module.
/// @param settlement Deployed settlement singleton.
/// @param collateral Deployed collateral token.
/// @param outcomeToken Deployed ERC-6909 outcome token.
/// @param market Deployed binary market.
/// @param pool Deployed recyclable pool.
/// @param marketNonce Exact generation nonce.
/// @param yesId Exact YES outcome ID.
/// @param noId Exact NO outcome ID.
/// @param tradingStart Trading start timestamp.
/// @param expiry Trading expiry timestamp.
/// @param oneCollateral One whole collateral unit.
/// @param setBacking Deployed generation backing at the pinned block.
/// @param marketExpiryNs Maximum venue order expiry in nanoseconds.
/// @param grid Deployed tick, minimum quantity, and lot size.
/// @param bestBid Pinned top bid used as the local mirror's price anchor.
/// @param bestAsk Pinned top ask used as the local mirror's price anchor.
/// @param moduleCodehash Pinned module runtime code hash.
/// @param poolCodehash Pinned pool runtime code hash.
/// @param sourceFingerprint Hash binding every safety-critical source value.
struct ShannonSnapshot {
  uint256 pinnedBlock;
  bytes32 marketId;
  address module;
  address settlement;
  address collateral;
  address outcomeToken;
  address market;
  address pool;
  uint64 marketNonce;
  uint256 yesId;
  uint256 noId;
  uint64 tradingStart;
  uint64 expiry;
  uint256 oneCollateral;
  uint256 setBacking;
  uint64 marketExpiryNs;
  IDreamDexBinaryPool.OrderBookParameters grid;
  IDreamDexBinaryPool.BookLevel bestBid;
  IDreamDexBinaryPool.BookLevel bestAsk;
  bytes32 moduleCodehash;
  bytes32 poolCodehash;
  bytes32 sourceFingerprint;
}

/// @notice Historical RPC reader shared by the fork-profile test and rehearsal script.
library ShannonSnapshotReader {
  string internal constant BLOCK_TAG = "0x1c68e9b0";
  uint256 internal constant PINNED_BLOCK = 476_637_616;

  address internal constant MODULE = 0x3ecC694Cef705358864a646142ac17A90E29e388;
  bytes32 internal constant MARKET_ID = bytes32(uint256(0xfc5b));
  address internal constant MARKET = 0x7c3b8d502D48F338af19A477929C47f07F4A7530;
  address internal constant POOL = 0x3bF5a4385af0d4DFd2eb38713Ae21D9FC82c0542;

  /// @notice Reads and binds the complete pinned source snapshot.
  /// @param vm Foundry cheatcode interface used for historical RPC calls.
  /// @return snapshot Validated deployed generation data.
  function read(Vm vm) internal returns (ShannonSnapshot memory snapshot) {
    DreamDexAdapter.ModuleMarket memory record = abi.decode(
      _rpcCall(vm, MODULE, abi.encodeCall(IDreamDexBinaryModule.markets, (MARKET_ID))),
      (DreamDexAdapter.ModuleMarket)
    );
    uint64 nonce = abi.decode(
      _rpcCall(vm, MODULE, abi.encodeCall(IDreamDexBinaryModule.marketNonce, (MARKET_ID))), (uint64)
    );
    address settlement = abi.decode(
      _rpcCall(vm, MODULE, abi.encodeCall(IDreamDexBinaryModule.settlement, ())), (address)
    );
    IDreamDexBinaryPool.BinaryPoolInfo memory info = abi.decode(
      _rpcCall(vm, POOL, abi.encodeCall(IDreamDexBinaryPool.getBinaryPoolParams, ())),
      (IDreamDexBinaryPool.BinaryPoolInfo)
    );
    IDreamDexBinaryPool.OrderBookParameters memory grid = abi.decode(
      _rpcCall(vm, POOL, abi.encodeCall(IDreamDexBinaryPool.getOrderBookParameters, ())),
      (IDreamDexBinaryPool.OrderBookParameters)
    );
    uint64 marketExpiryNs = abi.decode(
      _rpcCall(vm, POOL, abi.encodeCall(IDreamDexBinaryPool.marketExpiryNs, ())), (uint64)
    );
    // The bools are the deployed ABI's explicit bid- and ask-side selectors.
    // forge-lint: disable-start(boolean-cst)
    IDreamDexBinaryPool.BookLevel[] memory bids = abi.decode(
      _rpcCall(vm, POOL, abi.encodeCall(IDreamDexBinaryPool.getBookLevels, (true, 1))),
      (IDreamDexBinaryPool.BookLevel[])
    );
    IDreamDexBinaryPool.BookLevel[] memory asks = abi.decode(
      _rpcCall(vm, POOL, abi.encodeCall(IDreamDexBinaryPool.getBookLevels, (false, 1))),
      (IDreamDexBinaryPool.BookLevel[])
    );
    // forge-lint: disable-end(boolean-cst)
    uint8 status =
      abi.decode(_rpcCall(vm, MARKET, abi.encodeCall(IDreamDexBinaryMarket.status, ())), (uint8));

    require(record.market == MARKET && record.pool == POOL, "SOURCE_RECORD");
    require(nonce == info.marketNonce, "SOURCE_NONCE");
    require(record.yesId == info.yesId && record.noId == info.noId, "SOURCE_IDS");
    require(record.collateral == info.collateralToken, "SOURCE_COLLATERAL");
    require(settlement == info.settlement, "SOURCE_SETTLEMENT");
    require(!info.finalized && status == 1, "SOURCE_NOT_TRADING");
    require(bids.length != 0 && asks.length != 0, "SOURCE_EMPTY_BOOK");
    require(bids[0].price < asks[0].price, "SOURCE_CROSSED_BOOK");

    snapshot = ShannonSnapshot({
      pinnedBlock: PINNED_BLOCK,
      marketId: MARKET_ID,
      module: MODULE,
      settlement: settlement,
      collateral: record.collateral,
      outcomeToken: info.outcomeToken,
      market: MARKET,
      pool: POOL,
      marketNonce: nonce,
      yesId: record.yesId,
      noId: record.noId,
      tradingStart: record.tradingStart,
      expiry: record.expiry,
      oneCollateral: info.oneCollateral,
      setBacking: info.setBacking,
      marketExpiryNs: marketExpiryNs,
      grid: grid,
      bestBid: bids[0],
      bestAsk: asks[0],
      moduleCodehash: keccak256(_rpcCode(vm, MODULE)),
      poolCodehash: keccak256(_rpcCode(vm, POOL)),
      sourceFingerprint: bytes32(0)
    });
    snapshot.sourceFingerprint = keccak256(
      abi.encode(
        snapshot.pinnedBlock,
        snapshot.marketId,
        snapshot.module,
        snapshot.market,
        snapshot.pool,
        snapshot.marketNonce,
        snapshot.yesId,
        snapshot.noId,
        snapshot.expiry,
        snapshot.oneCollateral,
        snapshot.grid,
        snapshot.bestBid,
        snapshot.bestAsk,
        snapshot.moduleCodehash,
        snapshot.poolCodehash
      )
    );
  }

  /// @notice Executes one historical read-only call.
  /// @param vm Foundry cheatcode interface.
  /// @param target Deployed contract called.
  /// @param callData ABI-encoded selector and arguments.
  /// @return result ABI-encoded return data.
  function _rpcCall(Vm vm, address target, bytes memory callData)
    private
    returns (bytes memory result)
  {
    string memory params = string.concat(
      "[{\"to\":\"",
      vm.toString(target),
      "\",\"data\":\"",
      vm.toString(callData),
      "\"},\"",
      BLOCK_TAG,
      "\"]"
    );
    result = vm.rpc("somnia_testnet", "eth_call", params);
  }

  /// @notice Reads deployed bytecode at the pinned block.
  /// @param vm Foundry cheatcode interface.
  /// @param account Contract address read.
  /// @return code Runtime bytecode.
  function _rpcCode(Vm vm, address account) private returns (bytes memory code) {
    string memory params = string.concat("[\"", vm.toString(account), "\",\"", BLOCK_TAG, "\"]");
    code = vm.rpc("somnia_testnet", "eth_getCode", params);
  }
}
