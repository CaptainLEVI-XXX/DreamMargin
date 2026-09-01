// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary settlement test model
/// @author DreamMargin contributors
/// @notice Models frozen fee-scaled payout records and direct ERC-6909 redemption.
/// @dev Test-only controls can force reverts, callbacks, dishonest transfers, or dishonest returns.

import {IDreamDexBinarySettlement} from "src/interfaces/integrations/IDreamDexBinarySettlement.sol";

import {MockERC6909} from "test/mock/MockERC6909.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Raised when the mock is constructed without an outcome token.
error MockSettlementZeroAddress();

/// @notice Raised when redemption is deliberately disabled.
error MockSettlementRedemptionReverted();

/// @notice Raised when a redemption record is absent or not terminal.
/// @param marketKey Missing settlement key.
error MockSettlementNotFinal(uint256 marketKey);

/// @notice Raised when the requested outcome index is absent from the payout vector.
/// @param outcomeIndex Requested low-byte outcome index.
error MockSettlementOutcomeMissing(uint256 outcomeIndex);

/// @notice Raised when record backing cannot cover the calculated payout.
/// @param available Current record backing.
/// @param required Calculated payout.
error MockSettlementInsufficientBacking(uint256 available, uint256 required);

/// @notice Raised when the outcome-token movement reports failure.
error MockSettlementOutcomeTransferFailed();

/// @notice Local permanent settlement singleton model.
contract MockDreamDexBinarySettlement is IDreamDexBinarySettlement {
  using SafeTransferLib for address;

  /// @inheritdoc IDreamDexBinarySettlement
  address public immutable override outcomeToken;

  /// @notice Frozen record by `outcomeId >> 8`.
  mapping(uint256 marketKey => SettlementRecord record) private _records;

  /// @notice Whether direct redemption deliberately reverts.
  bool public redemptionReverts;

  /// @notice Whether the mock transfers a configured amount instead of the payout.
  bool public overrideTransfer;

  /// @notice Configured dishonest collateral transfer amount.
  uint256 public transferOverride;

  /// @notice Whether the mock returns a configured amount instead of the payout.
  bool public overrideReturn;

  /// @notice Configured dishonest return value.
  uint256 public returnOverride;

  /// @notice Optional callback target invoked while the settlement operator grant is live.
  address public callbackTarget;

  /// @notice Optional callback calldata.
  bytes public callbackData;

  /// @notice Whether the most recent callback succeeded.
  bool public lastCallbackSucceeded;

  /// @notice Return or revert data produced by the most recent callback.
  bytes public lastCallbackData;

  /// @notice Creates a settlement singleton bound to one shared outcome token.
  /// @param outcomeToken_ Shared ERC-6909 token contract.
  constructor(address outcomeToken_) {
    if (outcomeToken_ == address(0)) revert MockSettlementZeroAddress();
    outcomeToken = outcomeToken_;
  }

  /// @notice Stores a complete frozen settlement record.
  /// @param marketKey DreamDEX key derived as `outcomeId >> 8`.
  /// @param record Complete record including its current backing.
  function setSettlement(uint256 marketKey, SettlementRecord calldata record) external {
    _records[marketKey] = record;
  }

  /// @notice Configures dishonest or reverting redemption behavior.
  /// @param reverts_ Whether redemption reverts immediately.
  /// @param overrideTransfer_ Whether collateral movement uses `transferOverride_`.
  /// @param transferOverride_ Collateral amount actually transferred when overridden.
  /// @param overrideReturn_ Whether the return uses `returnOverride_`.
  /// @param returnOverride_ Reported amount when overridden.
  function setBehavior(
    bool reverts_,
    bool overrideTransfer_,
    uint256 transferOverride_,
    bool overrideReturn_,
    uint256 returnOverride_
  ) external {
    redemptionReverts = reverts_;
    overrideTransfer = overrideTransfer_;
    transferOverride = transferOverride_;
    overrideReturn = overrideReturn_;
    returnOverride = returnOverride_;
  }

  /// @notice Configures one best-effort callback during redemption.
  /// @param target Callback target.
  /// @param data Callback calldata.
  function configureCallback(address target, bytes calldata data) external {
    if (target == address(0)) revert MockSettlementZeroAddress();
    callbackTarget = target;
    callbackData = data;
  }

  /// @notice Clears the redemption callback.
  function clearCallback() external {
    callbackTarget = address(0);
    delete callbackData;
  }

  /// @inheritdoc IDreamDexBinarySettlement
  function redeem(uint256 outcomeId, uint256 amount, address to)
    external
    override
    returns (uint256 collateralOut)
  {
    if (redemptionReverts) revert MockSettlementRedemptionReverted();
    uint256 marketKey = outcomeId >> 8;
    SettlementRecord storage record = _records[marketKey];
    if (!record.finalized) revert MockSettlementNotFinal(marketKey);
    uint256 outcomeIndex = outcomeId & 0xff;
    if (outcomeIndex >= record.payoutNumerators.length) {
      revert MockSettlementOutcomeMissing(outcomeIndex);
    }

    if (callbackTarget != address(0)) {
      (lastCallbackSucceeded, lastCallbackData) = callbackTarget.call(callbackData);
    }
    bool transferred =
      MockERC6909(outcomeToken).transferFrom(msg.sender, address(this), outcomeId, amount);
    if (!transferred) revert MockSettlementOutcomeTransferFailed();
    MockERC6909(outcomeToken).burn(address(this), outcomeId, amount);

    uint256 payout =
      FixedPointMathLib.fullMulDiv(amount, record.payoutNumerators[outcomeIndex], 10_000_000);
    if (payout > record.backing) {
      revert MockSettlementInsufficientBacking(record.backing, payout);
    }
    // The preceding backing comparison proves the subtraction remains within uint128.
    // forge-lint: disable-next-line(unsafe-typecast)
    record.backing = uint128(uint256(record.backing) - payout);
    uint256 transferAmount = overrideTransfer ? transferOverride : payout;
    if (transferAmount != 0) record.collateralToken.safeTransfer(to, transferAmount);
    collateralOut = overrideReturn ? returnOverride : payout;
  }

  /// @inheritdoc IDreamDexBinarySettlement
  function getSettlement(uint256 marketKey)
    external
    view
    override
    returns (SettlementRecord memory record)
  {
    record = _records[marketKey];
  }

  /// @inheritdoc IDreamDexBinarySettlement
  function isFinalized(uint256 outcomeId) external view override returns (bool finalized) {
    finalized = _records[outcomeId >> 8].finalized;
  }
}
