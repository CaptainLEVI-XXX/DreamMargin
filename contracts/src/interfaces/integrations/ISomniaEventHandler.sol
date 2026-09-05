// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Somnia on-chain event handler interface
/// @author Somnia Foundation
/// @notice Receives one matched event from the privileged Reactivity precompile.
/// @dev Selector-compatible minimal interface pinned from reactivity-contracts 0.2.1.
interface ISomniaEventHandler {
  /// @notice Handles one event delivered by native on-chain Reactivity.
  /// @param emitter Contract that emitted the matched log.
  /// @param eventTopics Ordered event topics, beginning with the signature topic.
  /// @param data ABI-encoded non-indexed event data.
  function onEvent(address emitter, bytes32[] calldata eventTopics, bytes calldata data) external;
}
