// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary market test model
/// @author DreamMargin contributors
/// @notice Models generation assets, status, expiry, and terminal payout state.
/// @dev Mutable setters let adversarial tests change status between adapter reads.

import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";

/// @notice Raised when a required mock integration address is zero.
error MockDreamDexZeroAddress();

/// @notice Local DreamDEX binary-market state model.
contract MockDreamDexBinaryMarket is IDreamDexBinaryMarket {
  /// @inheritdoc IDreamDexBinaryMarket
  address public override outcomeToken;

  /// @inheritdoc IDreamDexBinaryMarket
  uint256 public override yesId;

  /// @inheritdoc IDreamDexBinaryMarket
  uint256 public override noId;

  /// @inheritdoc IDreamDexBinaryMarket
  address public override pool;

  /// @inheritdoc IDreamDexBinaryMarket
  address public override collateral;

  /// @inheritdoc IDreamDexBinaryMarket
  uint8 public override status;

  /// @inheritdoc IDreamDexBinaryMarket
  uint256 public override backing;

  /// @inheritdoc IDreamDexBinaryMarket
  uint64 public override expiry;

  /// @inheritdoc IDreamDexBinaryMarket
  uint64 public override settlementWindow;

  /// @notice Whether the market has resolved.
  bool private _resolved;

  /// @notice Whether the resolved market is voided.
  bool private _voided;

  /// @notice Terminal payout numerators.
  uint256[] private _payoutNumerators;

  /// @notice Creates one mutable market generation.
  /// @param outcomeToken_ Shared outcome-token contract.
  /// @param yesId_ YES token ID.
  /// @param noId_ NO token ID.
  /// @param pool_ Binary pool address.
  /// @param collateral_ Collateral token address.
  /// @param expiry_ Trading expiry in seconds.
  constructor(
    address outcomeToken_,
    uint256 yesId_,
    uint256 noId_,
    address pool_,
    address collateral_,
    uint64 expiry_
  ) {
    if (outcomeToken_ == address(0) || pool_ == address(0) || collateral_ == address(0)) {
      revert MockDreamDexZeroAddress();
    }
    outcomeToken = outcomeToken_;
    yesId = yesId_;
    noId = noId_;
    pool = pool_;
    collateral = collateral_;
    expiry = expiry_;
    status = 1;
  }

  /// @notice Changes the current DreamDEX market status.
  /// @param status_ New status enum value.
  function setStatus(uint8 status_) external {
    status = status_;
  }

  /// @notice Changes the pool address to model an invalid binding.
  /// @param pool_ New pool address.
  function setPool(address pool_) external {
    if (pool_ == address(0)) revert MockDreamDexZeroAddress();
    pool = pool_;
  }

  /// @notice Changes market backing and the settlement window.
  /// @param backing_ New backing in raw collateral units.
  /// @param settlementWindow_ New settlement window in seconds.
  function setSettlementTerms(uint256 backing_, uint64 settlementWindow_) external {
    backing = backing_;
    settlementWindow = settlementWindow_;
  }

  /// @notice Records a terminal payout vector.
  /// @param numerators Per-outcome payout numerators.
  /// @param voided_ Whether the market is voided.
  function resolve(uint256[] calldata numerators, bool voided_) external {
    _payoutNumerators = numerators;
    _resolved = true;
    _voided = voided_;
    status = voided_ ? 5 : 4;
  }

  /// @inheritdoc IDreamDexBinaryMarket
  function payoutNumerators() external view override returns (uint256[] memory numerators) {
    numerators = _payoutNumerators;
  }

  /// @inheritdoc IDreamDexBinaryMarket
  function isResolved() external view override returns (bool resolved) {
    resolved = _resolved;
  }

  /// @inheritdoc IDreamDexBinaryMarket
  function isVoided() external view override returns (bool voided) {
    voided = _voided;
  }
}
