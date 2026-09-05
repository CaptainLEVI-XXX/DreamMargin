// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin reactive market observer
/// @author DreamMargin contributors
/// @notice Refreshes both outcome marks when either dedicated DreamDEX demo pool changes.
/// @dev Somnia validators invoke this stateless handler through native Reactivity. Each outcome
///      independently respects its configured update interval, so coalesced or repeated pool
///      events cannot force too-frequent observations.

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {ISomniaEventHandler} from "src/interfaces/integrations/ISomniaEventHandler.sol";

import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";

/// @notice Stateless two-pool callback handler for DreamMargin mark observations.
contract DreamMarginReactiveObserver is ISomniaEventHandler {
  /// @notice Fixed Somnia native Reactivity precompile address.
  address public constant REACTIVITY_PRECOMPILE = address(0x0100);

  /// @notice Bound DreamMargin mark oracle.
  address public immutable ORACLE;

  /// @notice Dedicated BTC DreamDEX pool.
  address public immutable BTC_POOL;

  /// @notice Dedicated ETH DreamDEX pool.
  address public immutable ETH_POOL;

  /// @notice BTC YES generation identifier.
  bytes32 public immutable BTC_YES_GENERATION;

  /// @notice BTC NO generation identifier.
  bytes32 public immutable BTC_NO_GENERATION;

  /// @notice ETH YES generation identifier.
  bytes32 public immutable ETH_YES_GENERATION;

  /// @notice ETH NO generation identifier.
  bytes32 public immutable ETH_NO_GENERATION;

  /// @notice Binds the handler to one oracle, two pools, and their four exact generations.
  /// @param oracle_ Deployed DreamMargin mark oracle.
  /// @param btcPool_ Dedicated BTC pool emitter.
  /// @param btcYesGeneration_ BTC YES generation hash.
  /// @param btcNoGeneration_ BTC NO generation hash.
  /// @param ethPool_ Dedicated ETH pool emitter.
  /// @param ethYesGeneration_ ETH YES generation hash.
  /// @param ethNoGeneration_ ETH NO generation hash.
  constructor(
    address oracle_,
    address btcPool_,
    bytes32 btcYesGeneration_,
    bytes32 btcNoGeneration_,
    address ethPool_,
    bytes32 ethYesGeneration_,
    bytes32 ethNoGeneration_
  ) {
    if (oracle_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("ORACLE");
    if (btcPool_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("BTC_POOL");
    if (ethPool_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("ETH_POOL");
    ORACLE = oracle_;
    BTC_POOL = btcPool_;
    BTC_YES_GENERATION = btcYesGeneration_;
    BTC_NO_GENERATION = btcNoGeneration_;
    ETH_POOL = ethPool_;
    ETH_YES_GENERATION = ethYesGeneration_;
    ETH_NO_GENERATION = ethNoGeneration_;
  }

  /// @inheritdoc ISomniaEventHandler
  function onEvent(address emitter, bytes32[] calldata, bytes calldata) external {
    if (msg.sender != REACTIVITY_PRECOMPILE) {
      revert LibDreamMarginErrors.NotReactivityPrecompile(msg.sender, REACTIVITY_PRECOMPILE);
    }
    if (emitter == BTC_POOL) {
      _observeWhenDue(BTC_YES_GENERATION);
      _observeWhenDue(BTC_NO_GENERATION);
      return;
    }
    if (emitter == ETH_POOL) {
      _observeWhenDue(ETH_YES_GENERATION);
      _observeWhenDue(ETH_NO_GENERATION);
      return;
    }
    revert LibDreamMarginErrors.UnsupportedCallbackEmitter(emitter);
  }

  /// @notice Reports ERC-165 and Somnia callback interface support.
  /// @param interfaceId Requested interface identifier.
  /// @return supported True for ERC-165 or `ISomniaEventHandler`.
  function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
    supported = interfaceId == 0x01ffc9a7 || interfaceId == type(ISomniaEventHandler).interfaceId;
  }

  /// @notice Records one mark only after its own immutable update interval has elapsed.
  /// @param generationKey Exact outcome generation to refresh.
  function _observeWhenDue(bytes32 generationKey) private {
    // The oracle owns the shared due-time check used by callbacks and position writes.
    // forge-lint: disable-next-line(unused-return)
    IDreamDexMarkOracle(ORACLE).observeIfDue(generationKey);
  }
}
