// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Configurable ERC-20 test collateral
/// @author DreamMargin contributors
/// @notice Models standard collateral balances and allowances at any decimals.
/// @dev This contract is test-only and deliberately exposes unrestricted minting.

import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";

/// @notice Raised when a transfer exceeds the sender's balance.
/// @param available Sender balance before the transfer.
/// @param required Requested transfer amount.
error MockERC20InsufficientBalance(uint256 available, uint256 required);

/// @notice Raised when a delegated transfer exceeds its allowance.
/// @param available Allowance before the transfer.
/// @param required Requested transfer amount.
error MockERC20InsufficientAllowance(uint256 available, uint256 required);

/// @notice Standard-behavior ERC-20 model used by local integration tests.
contract MockERC20 is IERC20Minimal {
  /// @notice Human-readable token name.
  string public name;

  /// @notice Human-readable token symbol.
  string public symbol;

  /// @notice Token decimals selected for the test deployment.
  uint8 private immutable _DECIMALS;

  /// @notice Total minted token supply.
  uint256 public totalSupply;

  /// @notice Token balance by account.
  mapping(address account => uint256 amount) public override balanceOf;

  /// @notice Allowance by owner and spender.
  mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;

  /// @notice Creates a collateral model.
  /// @param name_ Human-readable token name.
  /// @param symbol_ Human-readable token symbol.
  /// @param decimals_ Token decimal places.
  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    name = name_;
    symbol = symbol_;
    _DECIMALS = decimals_;
  }

  /// @inheritdoc IERC20Minimal
  function decimals() external view override returns (uint8 decimals_) {
    decimals_ = _DECIMALS;
  }

  /// @notice Mints test collateral to an account.
  /// @param receiver Account receiving the minted collateral.
  /// @param amount Amount minted in raw collateral units.
  function mint(address receiver, uint256 amount) public virtual {
    totalSupply += amount;
    balanceOf[receiver] += amount;
  }

  /// @inheritdoc IERC20Minimal
  function approve(address spender, uint256 amount) public virtual override returns (bool success) {
    allowance[msg.sender][spender] = amount;
    success = true;
  }

  /// @inheritdoc IERC20Minimal
  function transfer(address receiver, uint256 amount)
    public
    virtual
    override
    returns (bool success)
  {
    _transfer(msg.sender, receiver, amount);
    success = true;
  }

  /// @inheritdoc IERC20Minimal
  function transferFrom(address sender, address receiver, uint256 amount)
    public
    virtual
    override
    returns (bool success)
  {
    uint256 approved = allowance[sender][msg.sender];
    if (approved != type(uint256).max) {
      if (approved < amount) revert MockERC20InsufficientAllowance(approved, amount);
      allowance[sender][msg.sender] = approved - amount;
    }

    _transfer(sender, receiver, amount);
    success = true;
  }

  /// @notice Moves collateral between two accounts.
  /// @param sender Account whose balance decreases.
  /// @param receiver Account whose balance increases.
  /// @param amount Amount moved in raw collateral units.
  function _transfer(address sender, address receiver, uint256 amount) internal virtual {
    uint256 available = balanceOf[sender];
    if (available < amount) revert MockERC20InsufficientBalance(available, amount);

    unchecked {
      balanceOf[sender] = available - amount;
      balanceOf[receiver] += amount;
    }
  }
}
