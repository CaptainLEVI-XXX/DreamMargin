// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary market integration interface
/// @author DreamMargin contributors
/// @notice Exposes authoritative status, generation assets, expiry, and payout state.
/// @dev Market status is read on-chain and never inferred from an indexer.
interface IDreamDexBinaryMarket {
  /// @notice Returns the shared ERC-6909 outcome-token contract.
  /// @return token Outcome-token contract address.
  function outcomeToken() external view returns (address token);

  /// @notice Returns the current YES outcome ID.
  /// @return id ERC-6909 YES token ID.
  function yesId() external view returns (uint256 id);

  /// @notice Returns the current NO outcome ID.
  /// @return id ERC-6909 NO token ID.
  function noId() external view returns (uint256 id);

  /// @notice Returns the binary pool assigned to this market.
  /// @return pool_ Binary pool address.
  function pool() external view returns (address pool_);

  /// @notice Returns the market collateral token.
  /// @return collateral_ Collateral token address.
  function collateral() external view returns (address collateral_);

  /// @notice Returns the authoritative DreamDEX market status.
  /// @return status_ Market-state enum encoded as uint8.
  function status() external view returns (uint8 status_);

  /// @notice Returns collateral backing currently assigned to the market.
  /// @return amount Backing in raw collateral units.
  function backing() external view returns (uint256 amount);

  /// @notice Returns the trading expiry in seconds.
  /// @return expiry_ Unix timestamp in seconds.
  function expiry() external view returns (uint64 expiry_);

  /// @notice Returns the post-expiry oracle settlement window.
  /// @return window Settlement window in seconds.
  function settlementWindow() external view returns (uint64 window);

  /// @notice Returns the terminal payout vector.
  /// @return numerators Per-outcome payout numerators, empty before resolution.
  function payoutNumerators() external view returns (uint256[] memory numerators);

  /// @notice Returns whether the market has resolved.
  /// @return resolved True when a terminal payout is recorded.
  function isResolved() external view returns (bool resolved);

  /// @notice Returns whether the market was voided.
  /// @return voided True when the terminal result is void.
  function isVoided() external view returns (bool voided);
}
