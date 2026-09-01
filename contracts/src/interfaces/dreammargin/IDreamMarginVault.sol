// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin collateral vault interface
/// @author DreamMargin contributors
/// @notice Exposes cash-limited ERC-4626 behavior and controller-only debt accounting.
/// @dev Asset values use collateral native units; debt conversions round in favor of the vault.
interface IDreamMarginVault {
  /// @notice Emitted when vault shares move between accounts.
  /// @param sender Account whose share balance decreased, or zero on mint.
  /// @param receiver Account whose share balance increased, or zero on burn.
  /// @param shares Shares moved.
  event Transfer(address indexed sender, address indexed receiver, uint256 shares);

  /// @notice Emitted when a share owner changes an allowance.
  /// @param owner Account granting the allowance.
  /// @param spender Account receiving the allowance.
  /// @param shares New allowance.
  event Approval(address indexed owner, address indexed spender, uint256 shares);

  /// @notice Emitted after an ERC-4626 deposit or mint.
  /// @param caller Account supplying assets.
  /// @param receiver Account receiving shares.
  /// @param assets Assets received.
  /// @param shares Shares minted.
  event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);

  /// @notice Emitted after an ERC-4626 withdrawal or redemption.
  /// @param caller Account initiating the exit.
  /// @param receiver Account receiving assets.
  /// @param owner Account whose shares were burned.
  /// @param assets Assets paid.
  /// @param shares Shares burned.
  event Withdraw(
    address indexed caller,
    address indexed receiver,
    address indexed owner,
    uint256 assets,
    uint256 shares
  );

  /// @notice Emitted when the controller creates a performing receivable.
  /// @param receiver Account receiving borrowed assets.
  /// @param assets Assets lent.
  /// @param debtShares Debt shares minted.
  event Borrow(address indexed receiver, uint256 assets, uint256 debtShares);

  /// @notice Emitted when controller repayment retires debt shares.
  /// @param assets Assets received.
  /// @param debtShares Debt shares retired.
  event Repay(uint256 assets, uint256 debtShares);

  /// @notice Emitted when the global financing index advances.
  /// @param previousIndexWad Previous assets-per-debt-share index.
  /// @param nextIndexWad New assets-per-debt-share index.
  /// @param interestAccrued Newly collectible financing interest.
  event InterestAccrued(uint256 previousIndexWad, uint256 nextIndexWad, uint256 interestAccrued);

  /// @notice Emitted when first-loss reserve capital is funded.
  /// @param assets Assets locked for first-loss use.
  /// @param reserveShares Non-redeemable shares minted to the vault.
  event ReserveFunded(uint256 assets, uint256 reserveShares);

  /// @notice Emitted when demonstrably excess first-loss capital is released.
  /// @param receiver Account receiving reserve assets.
  /// @param assets Reserve assets transferred.
  /// @param reserveSharesBurned Non-redeemable reserve shares burned.
  event ReserveWithdrawn(address indexed receiver, uint256 assets, uint256 reserveSharesBurned);

  /// @notice Emitted when a receivable is removed and reserve capital is consumed.
  /// @param assetsWrittenOff Receivable removed.
  /// @param reserveUsed Funded reserve applied.
  /// @param reserveSharesBurned Non-redeemable shares burned.
  event DebtWrittenOff(uint256 assetsWrittenOff, uint256 reserveUsed, uint256 reserveSharesBurned);

  /// @notice Emitted when terminal recovery retires debt and realizes only the shortfall.
  /// @param debtShares Debt shares removed from performing receivables.
  /// @param assetsRepaid Actual terminal collateral received.
  /// @param assetsWrittenOff Unrecovered receivable removed.
  /// @param reserveUsed Funded reserve applied to the shortfall.
  /// @param reserveSharesBurned Non-redeemable shares burned.
  event DebtSettled(
    uint256 debtShares,
    uint256 assetsRepaid,
    uint256 assetsWrittenOff,
    uint256 reserveUsed,
    uint256 reserveSharesBurned
  );

  /// @notice Emitted when assets arrive after an earlier write-off.
  /// @param assets Assets actually recovered.
  event RecoveryRecorded(uint256 assets);

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

  /// @notice Returns the immutable credit-accounting controller.
  /// @return controller_ Sole controller address.
  function controller() external view returns (address controller_);

  /// @notice Returns the immutable annual simple financing rate.
  /// @return rateWad Annual rate in WAD.
  function annualRateWad() external view returns (uint256 rateWad);

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

  /// @notice Returns collateral tracked as internal cash, excluding direct donations.
  /// @return assets Accounted cash in asset native units.
  function internalCash() external view returns (uint256 assets);

  /// @notice Returns collectible principal before projected interest.
  /// @return assets Performing principal in asset native units.
  function performingDebt() external view returns (uint256 assets);

  /// @notice Returns stored collectible financing interest.
  /// @return assets Stored interest in asset native units.
  function collectibleInterest() external view returns (uint256 assets);

  /// @notice Returns the current projected debt index.
  /// @return indexWad Assets per debt share in WAD.
  function debtIndexWad() external view returns (uint256 indexWad);

  /// @notice Returns all outstanding controller debt shares.
  /// @return shares Outstanding debt shares.
  function totalDebtShares() external view returns (uint256 shares);

  /// @notice Returns funded reserve assets locked from ordinary exits.
  /// @return assets Funded reserve in asset native units.
  function protocolReserve() external view returns (uint256 assets);

  /// @notice Returns accounted cash unavailable to ordinary synchronous exits.
  /// @return assets Locked cash in asset native units.
  function lockedReserve() external view returns (uint256 assets);

  /// @notice Returns non-redeemable shares representing funded reserve capital.
  /// @return shares Reserve shares held by the vault itself.
  function protocolReserveShares() external view returns (uint256 shares);

  /// @notice Returns token balance not recognized by internal accounting.
  /// @return assets Unaccounted direct donations in asset native units.
  function unaccountedSurplus() external view returns (uint256 assets);

  /// @notice Returns cumulative receivables removed as bad debt.
  /// @return assets Cumulative bad debt in asset native units.
  function realizedBadDebt() external view returns (uint256 assets);

  /// @notice Returns cumulative post-write-off recoveries actually received.
  /// @return assets Cumulative recovered assets.
  function recoveredBadDebt() external view returns (uint256 assets);

  /// @notice Advances the immutable simple financing-rate index to the current timestamp.
  /// @return interestAccrued Newly stored collectible interest.
  function accrueInterest() external returns (uint256 interestAccrued);

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

  /// @notice Retires terminal debt using actual recovery before realizing the shortfall.
  /// @param debtShares Exact position debt shares removed.
  /// @param maxRecoveryAssets Maximum available collateral supplied against the receivable.
  /// @return assetsRepaid Actual collateral received.
  /// @return assetsWrittenOff Remaining receivable removed after recovery.
  /// @return reserveUsed Funded reserve applied to the shortfall.
  function settleDebt(uint256 debtShares, uint256 maxRecoveryAssets)
    external
    returns (uint256 assetsRepaid, uint256 assetsWrittenOff, uint256 reserveUsed);

  /// @notice Pulls controller assets into the governance-locked first-loss reserve.
  /// @param assets Reserve assets transferred in asset native units.
  /// @return reserveShares Locked shares minted to the vault itself.
  function fundReserve(uint256 assets) external returns (uint256 reserveShares);

  /// @notice Releases reserve capital only after debt and every realized loss are cleared.
  /// @param assets Reserve assets transferred in asset native units.
  /// @param receiver Account receiving the released reserve.
  /// @return reserveSharesBurned Locked shares burned from the vault.
  function withdrawReserve(uint256 assets, address receiver)
    external
    returns (uint256 reserveSharesBurned);

  /// @notice Records collateral actually recovered after an earlier write-off.
  /// @param assets Recovered collateral transferred in asset native units.
  function recordRecovery(uint256 assets) external;
}
