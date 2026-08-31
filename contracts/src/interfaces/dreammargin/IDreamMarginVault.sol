// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin collateral vault interface
/// @author DreamMargin contributors
/// @notice Exposes cash-limited ERC-4626 behavior and controller-only debt accounting.
/// @dev Asset values use collateral native units; debt conversions round in favor of the vault.
interface IDreamMarginVault {
  // -------------------------------------------------------------------------
  // ERC-20 share interface
  // -------------------------------------------------------------------------

  /// @notice Returns the vault-share name.
  /// @return name_ Human-readable share name.
  function name() external view returns (string memory name_);

  /// @notice Returns the vault-share symbol.
  /// @return symbol_ Human-readable share symbol.
  function symbol() external view returns (string memory symbol_);

  /// @notice Returns vault-share precision.
  /// @return decimals_ Number of vault-share decimal places.
  function decimals() external view returns (uint8 decimals_);

  /// @notice Returns total redeemable vault shares.
  /// @return supply Total share supply.
  function totalSupply() external view returns (uint256 supply);

  /// @notice Returns one account's vault-share balance.
  /// @param account Account queried.
  /// @return shares Vault shares held.
  function balanceOf(address account) external view returns (uint256 shares);

  /// @notice Returns a vault-share allowance.
  /// @param owner Share owner.
  /// @param spender Approved spender.
  /// @return shares Remaining share allowance.
  function allowance(address owner, address spender) external view returns (uint256 shares);

  /// @notice Approves a spender for vault shares.
  /// @param spender Account permitted to transfer shares.
  /// @param shares Share allowance.
  /// @return success True when the allowance is recorded.
  function approve(address spender, uint256 shares) external returns (bool success);

  /// @notice Transfers vault shares.
  /// @param receiver Share recipient.
  /// @param shares Shares transferred.
  /// @return success True when the transfer succeeds.
  function transfer(address receiver, uint256 shares) external returns (bool success);

  /// @notice Transfers approved vault shares.
  /// @param owner Share owner.
  /// @param receiver Share recipient.
  /// @param shares Shares transferred.
  /// @return success True when the transfer succeeds.
  function transferFrom(address owner, address receiver, uint256 shares)
    external
    returns (bool success);

  // -------------------------------------------------------------------------
  // ERC-4626 asset interface
  // -------------------------------------------------------------------------

  /// @notice Returns the collateral asset managed by the vault.
  /// @return asset_ Collateral token address.
  function asset() external view returns (address asset_);

  /// @notice Returns cash plus performing debt and collectible interest.
  /// @return assets Reported assets in collateral native units.
  function totalAssets() external view returns (uint256 assets);

  /// @notice Converts assets to shares with ordinary ERC-4626 view rounding down.
  /// @param assets Assets in collateral native units.
  /// @return shares Corresponding vault shares.
  function convertToShares(uint256 assets) external view returns (uint256 shares);

  /// @notice Converts shares to assets with ordinary ERC-4626 view rounding down.
  /// @param shares Vault shares.
  /// @return assets Corresponding assets in collateral native units.
  function convertToAssets(uint256 shares) external view returns (uint256 assets);

  /// @notice Returns the current per-receiver deposit limit.
  /// @param receiver Prospective share receiver.
  /// @return assets Maximum accepted assets in collateral native units.
  function maxDeposit(address receiver) external view returns (uint256 assets);

  /// @notice Returns the current per-receiver mint limit.
  /// @param receiver Prospective share receiver.
  /// @return shares Maximum shares that can be minted.
  function maxMint(address receiver) external view returns (uint256 shares);

  /// @notice Returns the maximum assets an account can withdraw against available cash.
  /// @param owner Share owner.
  /// @return assets Maximum immediately withdrawable assets.
  function maxWithdraw(address owner) external view returns (uint256 assets);

  /// @notice Returns the maximum shares an account can redeem against available cash.
  /// @param owner Share owner.
  /// @return shares Maximum immediately redeemable shares.
  function maxRedeem(address owner) external view returns (uint256 shares);

  /// @notice Previews shares minted for an exact asset deposit, rounded down.
  /// @param assets Assets deposited in collateral native units.
  /// @return shares Shares that would be minted.
  function previewDeposit(uint256 assets) external view returns (uint256 shares);

  /// @notice Previews assets required for exact shares, rounded up.
  /// @param shares Shares requested.
  /// @return assets Assets required in collateral native units.
  function previewMint(uint256 shares) external view returns (uint256 assets);

  /// @notice Previews shares burned for exact assets, rounded up.
  /// @param assets Assets requested in collateral native units.
  /// @return shares Shares that would be burned.
  function previewWithdraw(uint256 assets) external view returns (uint256 shares);

  /// @notice Previews assets paid for exact shares, rounded down.
  /// @param shares Shares redeemed.
  /// @return assets Assets that would be paid in collateral native units.
  function previewRedeem(uint256 shares) external view returns (uint256 assets);

  /// @notice Deposits exact assets and mints shares rounded down.
  /// @param assets Assets transferred in collateral native units.
  /// @param receiver Account receiving vault shares.
  /// @return shares Shares minted.
  function deposit(uint256 assets, address receiver) external returns (uint256 shares);

  /// @notice Mints exact shares for assets rounded up.
  /// @param shares Shares minted.
  /// @param receiver Account receiving vault shares.
  /// @return assets Assets transferred in collateral native units.
  function mint(uint256 shares, address receiver) external returns (uint256 assets);

  /// @notice Withdraws exact cash-backed assets and burns shares rounded up.
  /// @param assets Assets paid in collateral native units.
  /// @param receiver Account receiving assets.
  /// @param owner Account whose shares are burned.
  /// @return shares Shares burned.
  function withdraw(uint256 assets, address receiver, address owner)
    external
    returns (uint256 shares);

  /// @notice Redeems exact shares for cash-backed assets rounded down.
  /// @param shares Shares burned.
  /// @param receiver Account receiving assets.
  /// @param owner Account whose shares are burned.
  /// @return assets Assets paid in collateral native units.
  function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

  // -------------------------------------------------------------------------
  // Credit accounting
  // -------------------------------------------------------------------------

  /// @notice Returns cash not locked for the funded first-loss reserve.
  /// @return assets Available collateral in asset native units.
  function availableLiquidity() external view returns (uint256 assets);

  /// @notice Converts debt shares to current assets with upward rounding.
  /// @param debtShares Debt shares converted.
  /// @return assets Current debt in collateral native units.
  function debtAssets(uint256 debtShares) external view returns (uint256 assets);

  /// @notice Lends collateral to the controller and creates debt shares rounded up.
  /// @param assets Collateral borrowed in asset native units.
  /// @param receiver Account receiving borrowed collateral.
  /// @return debtShares Debt shares created.
  function borrow(uint256 assets, address receiver) external returns (uint256 debtShares);

  /// @notice Pulls controller collateral and burns debt shares after full reconciliation.
  /// @param debtShares Maximum debt shares retired.
  /// @param maxAssets Maximum collateral authorized for repayment.
  /// @return assetsRepaid Actual collateral received in asset native units.
  /// @return sharesRepaid Actual debt shares retired.
  function repay(uint256 debtShares, uint256 maxAssets)
    external
    returns (uint256 assetsRepaid, uint256 sharesRepaid);

  /// @notice Removes an uncollectible receivable and applies funded reserve once.
  /// @param debtShares Debt shares written off.
  /// @return assetsWrittenOff Receivable removed in asset native units.
  /// @return reserveUsed Funded reserve consumed in asset native units.
  function writeOff(uint256 debtShares)
    external
    returns (uint256 assetsWrittenOff, uint256 reserveUsed);

  /// @notice Records collateral actually recovered after an earlier write-off.
  /// @param assets Recovered collateral transferred in asset native units.
  function recordRecovery(uint256 assets) external;
}
