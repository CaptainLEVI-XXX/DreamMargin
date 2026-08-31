// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// @title DreamMargin vault storage
// @author DreamMargin contributors
// @notice Defines LP share, liquidity, debt, reserve, and loss state for the vault.
// @dev Mutable ERC-20 and ERC-4626-compatible fields live in this namespace rather than inherited storage.

// ERC-7201 slot for `dreammargin.storage.Vault`.
// Derivation: `keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff))`.
// Value: `0xa6fb530aaf39a19c3c563d8a35142da9fde0a76c31ba7bbba2512079941ee000`.
bytes32 constant DREAM_MARGIN_VAULT_STORAGE_SLOT =
  0xa6fb530aaf39a19c3c563d8a35142da9fde0a76c31ba7bbba2512079941ee000;

/// @title DreamMargin vault storage accessor
/// @author DreamMargin contributors
/// @notice Accesses and mutates DreamMargin vault state.
/// @dev Mutable ERC-20 and ERC-4626-compatible fields live only in this namespace.
library LibDreamMarginVaultStorage {
  /// @notice Complete mutable state of the DreamMargin vault.
  /// @param balanceOf Vault-share balance by account.
  /// @param allowance Vault-share allowance by owner and spender.
  /// @param totalSupply Total circulating redeemable vault shares.
  /// @param internalCash Collateral received and not currently lent, in asset native units.
  /// @param performingDebt Collectible principal receivable, in asset native units.
  /// @param collectibleInterest Accrued collectible financing interest, in asset native units.
  /// @param totalDebtShares Outstanding controller debt shares.
  /// @param debtIndexWad Assets per debt share in WAD, with debt conversion rounded up.
  /// @param lockedReserve Cash unavailable to ordinary LP withdrawals, in asset native units.
  /// @param protocolReserve Funded non-redeemable first-loss reserve, in asset native units.
  /// @param accruedProtocolFees Earned and collectible protocol fees, in asset native units.
  /// @param realizedBadDebt Cumulative written-off receivables, never subtracted twice.
  /// @param recoveredBadDebt Cumulative assets actually recovered after write-off.
  /// @param lastAccrual Last financing-index accrual timestamp in seconds.
  /// @param reentrancyStatus Current reentrancy-guard state.
  /// @param initialized Whether vault initialization has completed.
  struct State {
    mapping(address account => uint256 shares) balanceOf;
    mapping(address owner => mapping(address spender => uint256 shares)) allowance;
    uint256 totalSupply;
    uint256 internalCash;
    uint256 performingDebt;
    uint256 collectibleInterest;
    uint256 totalDebtShares;
    uint256 debtIndexWad;
    uint256 lockedReserve;
    uint256 protocolReserve;
    uint256 accruedProtocolFees;
    uint256 realizedBadDebt;
    uint256 recoveredBadDebt;
    uint40 lastAccrual;
    uint8 reentrancyStatus;
    bool initialized;
  }

  /// @notice Returns the vault state stored at its ERC-7201 namespace.
  /// @dev Memory layout: `slot` is one stack word containing the namespace root.
  ///      1. Bind the returned storage pointer to that root.
  ///      Safety Considerations: THE LITERAL SLOT DERIVATION IS VERIFIED BY TEST;
  ///      THIS ACCESSOR DOES NOT VALIDATE FIELD LAYOUT OR UPGRADE COMPATIBILITY.
  /// @return self Storage reference to the vault state.
  function get() internal pure returns (State storage self) {
    bytes32 slot = DREAM_MARGIN_VAULT_STORAGE_SLOT;
    assembly ("memory-safe") {
      self.slot := slot
    }
  }
}
