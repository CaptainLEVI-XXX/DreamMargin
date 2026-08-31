// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Minimal ERC-6909 outcome-token interface
/// @author DreamMargin contributors
/// @notice Exposes exact-ID balances, allowances, operators, and transfers.
/// @dev DreamMargin accepts user collateral through per-ID allowances. Global
///      operators cover every ID and are reserved for protocol-owned balances
///      interacting with a pinned DreamDEX spender that requires them.
interface IERC6909 {
  /// @notice Returns an owner's balance for one token ID.
  /// @param owner Account whose balance is queried.
  /// @param id Outcome-token ID.
  /// @return amount Balance in outcome-token units.
  function balanceOf(address owner, uint256 id) external view returns (uint256 amount);

  /// @notice Returns an exact-ID allowance.
  /// @param owner Account that owns the outcome tokens.
  /// @param spender Account permitted to transfer the outcome tokens.
  /// @param id Outcome-token ID covered by the allowance.
  /// @return amount Remaining allowance for the ID.
  function allowance(address owner, address spender, uint256 id)
    external
    view
    returns (uint256 amount);

  /// @notice Returns whether a spender is a global operator for an owner.
  /// @param owner Account that owns the outcome tokens.
  /// @param spender Account whose operator status is queried.
  /// @return approved True when the spender may transfer every ID.
  function isOperator(address owner, address spender) external view returns (bool approved);

  /// @notice Approves a spender for an exact token ID and amount.
  /// @param spender Account permitted to transfer the outcome tokens.
  /// @param id Outcome-token ID covered by the allowance.
  /// @param amount Allowance in outcome-token units.
  /// @return success True when the approval succeeds.
  function approve(address spender, uint256 id, uint256 amount) external returns (bool success);

  /// @notice Sets or removes a spender's global operator status.
  /// @param spender Account whose operator status changes.
  /// @param approved Whether the spender may transfer every ID.
  /// @return success True when the operator change succeeds.
  function setOperator(address spender, bool approved) external returns (bool success);

  /// @notice Transfers one token ID from the caller to a receiver.
  /// @param receiver Account that receives the outcome tokens.
  /// @param id Outcome-token ID transferred.
  /// @param amount Amount transferred in outcome-token units.
  /// @return success True when the transfer succeeds.
  function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);

  /// @notice Transfers one approved token ID between accounts.
  /// @param sender Account whose outcome tokens are transferred.
  /// @param receiver Account that receives the outcome tokens.
  /// @param id Outcome-token ID transferred.
  /// @param amount Amount transferred in outcome-token units.
  /// @return success True when the transfer succeeds.
  function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    returns (bool success);
}
