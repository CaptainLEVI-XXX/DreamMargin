// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin protocol constants
/// @author DreamMargin contributors
/// @notice Defines structural units, integration enums, roles, and fixed safety bounds.
/// @dev Economic risk parameters remain generation configuration and are not hard-coded here.
library LibDreamMarginConstants {
  // -------------------------------------------------------------------------
  // Units
  // -------------------------------------------------------------------------

  /// @notice One whole WAD used by fixed-point ratios.
  uint256 internal constant WAD = 1e18;

  /// @notice One hundred percent in basis points.
  uint256 internal constant BPS = 10_000;

  /// @notice One hundred percent in DreamDEX's basis-points-times-one-thousand unit.
  uint256 internal constant BPS_TIMES_1K = 10_000_000;

  /// @notice Denominator of DreamDEX's frozen fee-scaled settlement payout vector.
  uint256 internal constant SETTLEMENT_PAYOUT_DENOMINATOR = 10_000_000;

  /// @notice Number of nanoseconds in one second.
  uint256 internal constant NS_PER_SECOND = 1e9;

  /// @notice Fixed year length used by the simple testnet financing index.
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  // -------------------------------------------------------------------------
  // Sentinels and structural bounds
  // -------------------------------------------------------------------------

  /// @notice First valid position identifier; zero remains the missing-position sentinel.
  uint256 internal constant FIRST_POSITION_ID = 1;

  /// @notice Largest supported collateral precision.
  uint8 internal constant MAX_COLLATERAL_DECIMALS = 18;

  /// @notice Largest book walk accepted by protocol configuration.
  uint16 internal constant MAX_BOOK_LEVELS = 64;

  /// @notice Largest bounded observation ring accepted by oracle configuration.
  uint16 internal constant MAX_OBSERVATIONS = 256;

  // -------------------------------------------------------------------------
  // DreamDEX integration values
  // -------------------------------------------------------------------------

  /// @notice DreamDEX order kind for buying YES.
  uint8 internal constant ORDER_KIND_BUY_YES = 0;

  /// @notice DreamDEX order kind for selling YES.
  uint8 internal constant ORDER_KIND_SELL_YES = 1;

  /// @notice DreamDEX order kind for buying NO.
  uint8 internal constant ORDER_KIND_BUY_NO = 2;

  /// @notice DreamDEX order kind for selling NO.
  uint8 internal constant ORDER_KIND_SELL_NO = 3;

  /// @notice DreamDEX fill-or-kill order type.
  uint8 internal constant ORDER_TYPE_FOK = 1;

  /// @notice DreamDEX immediate-or-cancel order type.
  uint8 internal constant ORDER_TYPE_IOC = 2;

  /// @notice DreamDEX listed market status.
  uint8 internal constant MARKET_STATUS_LISTED = 0;

  /// @notice DreamDEX actively trading market status.
  uint8 internal constant MARKET_STATUS_TRADING = 1;

  /// @notice DreamDEX locked market status.
  uint8 internal constant MARKET_STATUS_LOCKED = 2;

  /// @notice DreamDEX settling market status.
  uint8 internal constant MARKET_STATUS_SETTLING = 3;

  /// @notice DreamDEX resolved market status.
  uint8 internal constant MARKET_STATUS_RESOLVED = 4;

  /// @notice DreamDEX voided market status.
  uint8 internal constant MARKET_STATUS_VOIDED = 5;

  // -------------------------------------------------------------------------
  // Role bits
  // -------------------------------------------------------------------------

  /// @notice Governance role for delayed high-impact changes and role administration.
  uint256 internal constant ROLE_GOVERNANCE = 1 << 0;

  /// @notice Risk-steward role for bounded market admission and cap reductions.
  uint256 internal constant ROLE_RISK_STEWARD = 1 << 1;

  /// @notice Guardian role for pause, reduce-only mode, freezes, and risk reduction.
  uint256 internal constant ROLE_GUARDIAN = 1 << 2;

  /// @notice Fee-collector role for forwarding already accrued protocol fees.
  uint256 internal constant ROLE_FEE_COLLECTOR = 1 << 3;

  /// @notice Optional keeper role for explicitly keeper-gated maintenance.
  uint256 internal constant ROLE_KEEPER = 1 << 4;

  // -------------------------------------------------------------------------
  // Reentrancy states
  // -------------------------------------------------------------------------

  /// @notice Reentrancy guard state outside an external interaction.
  uint8 internal constant REENTRANCY_UNLOCKED = 1;

  /// @notice Reentrancy guard state during a protected interaction.
  uint8 internal constant REENTRANCY_LOCKED = 2;
}
