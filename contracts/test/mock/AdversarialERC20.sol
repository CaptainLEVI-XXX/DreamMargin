// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Adversarial ERC-20 collateral models
/// @author DreamMargin contributors
/// @notice Exercises fee-on-transfer and callback behavior rejected by the vault.
/// @dev Test-only controls deliberately permit changing transfer behavior at any time.

import {MockERC20, MockERC20InsufficientBalance} from "test/mock/MockERC20.sol";

/// @notice ERC-20 model that burns a configurable portion of every transfer.
contract MockFeeOnTransferERC20 is MockERC20 {
  /// @notice Transfer fee in basis points.
  uint256 public feeBps;

  /// @notice Creates a six-decimal fee-on-transfer collateral model.
  constructor() MockERC20("Fee Collateral", "FEE", 6) {}

  /// @notice Changes the test transfer fee.
  /// @param feeBps_ New fee in basis points, at most one hundred percent.
  function setFeeBps(uint256 feeBps_) external {
    require(feeBps_ <= 10_000, "FEE_TOO_HIGH");
    feeBps = feeBps_;
  }

  /// @notice Moves the net amount and burns the configured fee.
  /// @param sender Account whose balance decreases by the gross amount.
  /// @param receiver Account receiving the net amount.
  /// @param amount Gross transfer amount.
  function _transfer(address sender, address receiver, uint256 amount) internal override {
    uint256 available = balanceOf[sender];
    if (available < amount) revert MockERC20InsufficientBalance(available, amount);
    uint256 fee = amount * feeBps / 10_000;
    uint256 received = amount - fee;
    unchecked {
      balanceOf[sender] = available - amount;
      balanceOf[receiver] += received;
      totalSupply -= fee;
    }
  }
}

/// @notice ERC-20 model that calls an arbitrary target during delegated transfers.
contract MockCallbackERC20 is MockERC20 {
  /// @notice Callback target used by the next delegated transfer.
  address public callbackTarget;

  /// @notice Callback calldata used by the next delegated transfer.
  bytes public callbackData;

  /// @notice Whether delegated transfers currently invoke the callback.
  bool public callbackEnabled;

  /// @notice Whether the most recent configured callback succeeded.
  bool public lastCallbackSucceeded;

  /// @notice Return or revert data produced by the most recent callback.
  bytes public lastCallbackReturnData;

  /// @notice Prevents this test token from recursively invoking itself.
  bool private _insideCallback;

  /// @notice Creates a six-decimal callback-enabled collateral model.
  constructor() MockERC20("Callback Collateral", "CALL", 6) {}

  /// @notice Configures a callback for delegated transfers.
  /// @param target Contract called during transfer.
  /// @param data Calldata forwarded to the target.
  function configureCallback(address target, bytes calldata data) external {
    require(target != address(0), "ZERO_TARGET");
    callbackTarget = target;
    callbackData = data;
    callbackEnabled = true;
  }

  /// @notice Disables the configured callback.
  function disableCallback() external {
    callbackEnabled = false;
  }

  /// @notice Executes the configured callback before the ordinary delegated transfer.
  /// @param sender Account whose tokens move.
  /// @param receiver Account receiving tokens.
  /// @param amount Gross transfer amount.
  /// @return success True when the callback and transfer both succeed.
  function transferFrom(address sender, address receiver, uint256 amount)
    public
    override
    returns (bool success)
  {
    if (callbackEnabled && !_insideCallback) {
      _insideCallback = true;
      (lastCallbackSucceeded, lastCallbackReturnData) = callbackTarget.call(callbackData);
      _insideCallback = false;
    }
    success = super.transferFrom(sender, receiver, amount);
  }
}
