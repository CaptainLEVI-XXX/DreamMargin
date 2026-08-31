// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Minimal ERC-20 integration interface
/// @author DreamMargin contributors
/// @notice Exposes only the collateral-token functions used by DreamMargin.
/// @dev Transfer calls are executed through Solady's SafeTransferLib so tokens
///      that omit Boolean return data are handled without widening this ABI.
interface IERC20Minimal {
  /// @notice Returns the token's display decimals.
  /// @return decimals_ Number of decimal places used by token amounts.
  function decimals() external view returns (uint8 decimals_);

  /// @notice Returns an account's token balance.
  /// @param account Account whose balance is queried.
  /// @return amount Token balance in raw token units.
  function balanceOf(address account) external view returns (uint256 amount);

  /// @notice Returns the amount an owner approved for a spender.
  /// @param owner Account that owns the tokens.
  /// @param spender Account permitted to spend the tokens.
  /// @return amount Remaining allowance in raw token units.
  function allowance(address owner, address spender) external view returns (uint256 amount);

  /// @notice Approves a spender for an amount of tokens.
  /// @param spender Account permitted to spend the tokens.
  /// @param amount Allowance in raw token units.
  /// @return success True when the approval succeeds.
  function approve(address spender, uint256 amount) external returns (bool success);

  /// @notice Transfers tokens from the caller to a receiver.
  /// @param receiver Account that receives the tokens.
  /// @param amount Amount transferred in raw token units.
  /// @return success True when the transfer succeeds.
  function transfer(address receiver, uint256 amount) external returns (bool success);

  /// @notice Transfers approved tokens between accounts.
  /// @param sender Account whose tokens are transferred.
  /// @param receiver Account that receives the tokens.
  /// @param amount Amount transferred in raw token units.
  /// @return success True when the transfer succeeds.
  function transferFrom(address sender, address receiver, uint256 amount)
    external
    returns (bool success);
}
