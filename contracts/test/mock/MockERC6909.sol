// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Configurable ERC-6909 test outcome token
/// @author DreamMargin contributors
/// @notice Models exact-ID allowances and global operator authorization.
/// @dev This contract is test-only and deliberately exposes unrestricted mint
///      and burn functions for DreamDEX integration models.

import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

/// @notice Raised when a transfer is not authorized for the exact owner and ID.
/// @param owner Outcome-token owner.
/// @param spender Account attempting the transfer.
/// @param id Outcome-token ID.
error MockERC6909Unauthorized(address owner, address spender, uint256 id);

/// @notice Raised when a transfer exceeds the owner's balance for an ID.
/// @param available Exact-ID balance before the transfer.
/// @param required Requested transfer amount.
error MockERC6909InsufficientBalance(uint256 available, uint256 required);

/// @notice Standard-behavior ERC-6909 model used by local integration tests.
contract MockERC6909 is IERC6909 {
  /// @notice Balance by owner and token ID.
  mapping(address owner => mapping(uint256 id => uint256 amount)) public override balanceOf;

  /// @notice Allowance by owner, spender, and exact token ID.
  mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount)))
    public
    override allowance;

  /// @notice Global operator approval by owner and spender.
  mapping(address owner => mapping(address spender => bool approved)) public override isOperator;

  /// @notice Mints an outcome-token ID to an account.
  /// @param receiver Account receiving the outcome tokens.
  /// @param id Outcome-token ID minted.
  /// @param amount Amount minted in outcome-token units.
  function mint(address receiver, uint256 id, uint256 amount) external {
    balanceOf[receiver][id] += amount;
  }

  /// @notice Burns an outcome-token ID from an account.
  /// @param owner Account whose outcome tokens are burned.
  /// @param id Outcome-token ID burned.
  /// @param amount Amount burned in outcome-token units.
  function burn(address owner, uint256 id, uint256 amount) external {
    uint256 available = balanceOf[owner][id];
    if (available < amount) revert MockERC6909InsufficientBalance(available, amount);
    unchecked {
      balanceOf[owner][id] = available - amount;
    }
  }

  /// @inheritdoc IERC6909
  function approve(address spender, uint256 id, uint256 amount)
    external
    override
    returns (bool success)
  {
    allowance[msg.sender][spender][id] = amount;
    success = true;
  }

  /// @inheritdoc IERC6909
  function setOperator(address spender, bool approved) external override returns (bool success) {
    isOperator[msg.sender][spender] = approved;
    success = true;
  }

  /// @inheritdoc IERC6909
  function transfer(address receiver, uint256 id, uint256 amount)
    external
    override
    returns (bool success)
  {
    _transfer(msg.sender, receiver, id, amount);
    success = true;
  }

  /// @inheritdoc IERC6909
  function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
    external
    override
    returns (bool success)
  {
    if (msg.sender != sender && !isOperator[sender][msg.sender]) {
      uint256 approved = allowance[sender][msg.sender][id];
      if (approved < amount) revert MockERC6909Unauthorized(sender, msg.sender, id);
      if (approved != type(uint256).max) allowance[sender][msg.sender][id] = approved - amount;
    }

    _transfer(sender, receiver, id, amount);
    success = true;
  }

  /// @notice Moves one exact outcome-token ID between accounts.
  /// @param sender Account whose exact-ID balance decreases.
  /// @param receiver Account whose exact-ID balance increases.
  /// @param id Outcome-token ID moved.
  /// @param amount Amount moved in outcome-token units.
  function _transfer(address sender, address receiver, uint256 id, uint256 amount) internal {
    uint256 available = balanceOf[sender][id];
    if (available < amount) revert MockERC6909InsufficientBalance(available, amount);

    unchecked {
      balanceOf[sender][id] = available - amount;
      balanceOf[receiver][id] += amount;
    }
  }
}
