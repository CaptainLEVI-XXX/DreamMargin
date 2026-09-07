// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Somnia Reactivity precompile interface
/// @author Somnia Foundation
/// @notice Creates, removes, and reads native on-chain event subscriptions.
/// @dev Selector-compatible minimal interface pinned from reactivity-contracts 0.2.1.
interface ISomniaReactivityPrecompile {
  /// @notice Complete event filter and callback execution policy.
  /// @param eventTopics Four positional topic filters; zero values are wildcards.
  /// @param origin Optional transaction-origin filter; zero is a wildcard.
  /// @param caller Reserved caller filter; must currently be zero.
  /// @param emitter Optional event-emitter filter; zero is a wildcard.
  /// @param handlerContractAddress Contract receiving matching callbacks.
  /// @param handlerFunctionSelector Callback selector, normally `onEvent`.
  /// @param priorityFeePerGas Validator priority fee in wei per gas.
  /// @param maxFeePerGas Maximum callback fee in wei per gas.
  /// @param gasLimit Maximum gas provisioned to one callback.
  /// @param isGuaranteed Whether a full block defers rather than drops delivery.
  /// @param isCoalesced Whether matching events may share one callback per block.
  struct SubscriptionData {
    bytes32[4] eventTopics;
    address origin;
    address caller;
    address emitter;
    address handlerContractAddress;
    bytes4 handlerFunctionSelector;
    uint64 priorityFeePerGas;
    uint64 maxFeePerGas;
    uint64 gasLimit;
    bool isGuaranteed;
    bool isCoalesced;
  }

  /// @notice Creates a subscription owned and funded by the caller.
  /// @param subscriptionData Exact event filter and callback policy.
  /// @return subscriptionId New chain-wide subscription identifier.
  function subscribe(SubscriptionData calldata subscriptionData)
    external
    returns (uint256 subscriptionId);

  /// @notice Cancels a subscription owned by the caller.
  /// @param subscriptionId Existing chain-wide identifier.
  function unsubscribe(uint256 subscriptionId) external;

  /// @notice Returns one subscription and its funding owner.
  /// @param subscriptionId Existing chain-wide identifier.
  /// @return subscriptionData Stored event filter and callback policy.
  /// @return owner Account paying for and controlling the subscription.
  function getSubscriptionInfo(uint256 subscriptionId)
    external
    view
    returns (SubscriptionData memory subscriptionData, address owner);
}
