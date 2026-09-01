// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin collateral vault
/// @author DreamMargin contributors
/// @notice Supplies cash-limited ERC-4626 liquidity and conservative controller credit.
/// @dev Mutable state is isolated in an ERC-7201 namespace; immutable bindings cannot be rebound.

import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {LibDreamMarginVaultStorage} from "src/libs/dreammargin/LibDreamMarginVaultStorage.sol";
import {LibPositionRisk} from "src/libs/dreammargin/LibPositionRisk.sol";
import {DreamMarginReentrancyGuard} from "src/libs/dreammargin/DreamMarginReentrancyGuard.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// Forge cannot currently infer the inherited Solady transient lock held across external calls.
// forge-lint: disable-start(reentrancy-events)

/// @notice ERC-4626-compatible vault shares backed by cash and performing controller receivables.
contract DreamMarginVault is IDreamMarginVault, DreamMarginReentrancyGuard {
  // -------------------------------------------------------------------------
  // Immutable configuration
  // -------------------------------------------------------------------------

  /// @notice Collateral token managed by this deployment.
  address private immutable _ASSET;

  /// @notice Sole account authorized to create, repay, or write off receivables.
  address private immutable _CONTROLLER;

  /// @notice Collateral precision copied at deployment.
  uint8 private immutable _ASSET_DECIMALS;

  /// @notice Simple annual financing rate applied to the global debt index.
  uint256 private immutable _ANNUAL_RATE_WAD;

  /// @notice Virtual assets used by every vault-share conversion.
  uint256 private constant _VIRTUAL_ASSETS = 1;

  /// @notice Virtual shares create six extra decimals of first-deposit protection.
  uint256 private constant _VIRTUAL_SHARES = 1e6;

  // -------------------------------------------------------------------------
  // Construction and modifiers
  // -------------------------------------------------------------------------

  /// @notice Binds one collateral asset, controller, and immutable testnet financing rate.
  /// @param asset_ Collateral token managed by the vault.
  /// @param controller_ Sole credit-accounting controller.
  /// @param annualRateWad_ Annual simple financing rate in WAD.
  constructor(address asset_, address controller_, uint256 annualRateWad_) {
    if (asset_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("ASSET");
    if (controller_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("CONTROLLER");

    uint8 assetDecimals = IERC20Minimal(asset_).decimals();
    if (assetDecimals > LibDreamMarginConstants.MAX_COLLATERAL_DECIMALS) {
      revert LibDreamMarginErrors.UnsupportedDecimals(
        assetDecimals, LibDreamMarginConstants.MAX_COLLATERAL_DECIMALS
      );
    }

    _ASSET = asset_;
    _CONTROLLER = controller_;
    _ASSET_DECIMALS = assetDecimals;
    _ANNUAL_RATE_WAD = annualRateWad_;

    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.debtIndexWad = LibDreamMarginConstants.WAD;
    self.lastAccrual = _timestamp40();
    self.initialized = true;
  }

  /// @notice Restricts credit and reserve accounting to the immutable controller.
  modifier onlyController() {
    if (msg.sender != _CONTROLLER) {
      revert LibDreamMarginErrors.NotController(msg.sender, _CONTROLLER);
    }
    _;
  }

  // -------------------------------------------------------------------------
  // ERC-20 share views and movement
  // -------------------------------------------------------------------------

  /// @inheritdoc IDreamMarginVault
  function name() external pure returns (string memory name_) {
    name_ = "DreamMargin Vault Share";
  }

  /// @inheritdoc IDreamMarginVault
  function symbol() external pure returns (string memory symbol_) {
    symbol_ = "dmSHARE";
  }

  /// @inheritdoc IDreamMarginVault
  function decimals() external view returns (uint8 decimals_) {
    decimals_ = _ASSET_DECIMALS + 6;
  }

  /// @inheritdoc IDreamMarginVault
  function totalSupply() public view returns (uint256 supply) {
    supply = LibDreamMarginVaultStorage.get().totalSupply;
  }

  /// @inheritdoc IDreamMarginVault
  function balanceOf(address account) public view returns (uint256 shares) {
    shares = LibDreamMarginVaultStorage.get().balanceOf[account];
  }

  /// @inheritdoc IDreamMarginVault
  function allowance(address owner, address spender) external view returns (uint256 shares) {
    shares = LibDreamMarginVaultStorage.get().allowance[owner][spender];
  }

  /// @inheritdoc IDreamMarginVault
  function approve(address spender, uint256 shares) external returns (bool success) {
    LibDreamMarginVaultStorage.get().allowance[msg.sender][spender] = shares;
    emit Approval(msg.sender, spender, shares);
    success = true;
  }

  /// @inheritdoc IDreamMarginVault
  function transfer(address receiver, uint256 shares) external returns (bool success) {
    _transferShares(msg.sender, receiver, shares);
    success = true;
  }

  /// @inheritdoc IDreamMarginVault
  function transferFrom(address owner, address receiver, uint256 shares)
    external
    returns (bool success)
  {
    _spendAllowance(owner, msg.sender, shares);
    _transferShares(owner, receiver, shares);
    success = true;
  }

  // -------------------------------------------------------------------------
  // ERC-4626 views
  // -------------------------------------------------------------------------

  /// @inheritdoc IDreamMarginVault
  function asset() external view returns (address asset_) {
    asset_ = _ASSET;
  }

  /// @inheritdoc IDreamMarginVault
  function controller() external view returns (address controller_) {
    controller_ = _CONTROLLER;
  }

  /// @inheritdoc IDreamMarginVault
  function annualRateWad() external view returns (uint256 rateWad) {
    rateWad = _ANNUAL_RATE_WAD;
  }

  /// @inheritdoc IDreamMarginVault
  function totalAssets() public view returns (uint256 assets) {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    assets = self.internalCash + _projectedReceivable(self);
  }

  /// @inheritdoc IDreamMarginVault
  function convertToShares(uint256 assets) public view returns (uint256 shares) {
    shares = LibPositionRisk.vaultSharesDown(
      assets, totalSupply(), totalAssets(), _VIRTUAL_SHARES, _VIRTUAL_ASSETS
    );
  }

  /// @inheritdoc IDreamMarginVault
  function convertToAssets(uint256 shares) public view returns (uint256 assets) {
    assets = LibPositionRisk.vaultAssetsDown(
      shares, totalSupply(), totalAssets(), _VIRTUAL_SHARES, _VIRTUAL_ASSETS
    );
  }

  /// @inheritdoc IDreamMarginVault
  function maxDeposit(address) external pure returns (uint256 assets) {
    assets = type(uint256).max;
  }

  /// @inheritdoc IDreamMarginVault
  function maxMint(address) external pure returns (uint256 shares) {
    shares = type(uint256).max;
  }

  /// @inheritdoc IDreamMarginVault
  function maxWithdraw(address owner) public view returns (uint256 assets) {
    uint256 ownerAssets = convertToAssets(balanceOf(owner));
    uint256 liquidity = availableLiquidity();
    assets = ownerAssets < liquidity ? ownerAssets : liquidity;
  }

  /// @inheritdoc IDreamMarginVault
  function maxRedeem(address owner) public view returns (uint256 shares) {
    uint256 cashShares = convertToShares(availableLiquidity());
    uint256 ownerShares = balanceOf(owner);
    shares = ownerShares < cashShares ? ownerShares : cashShares;
  }

  /// @inheritdoc IDreamMarginVault
  function previewDeposit(uint256 assets) public view returns (uint256 shares) {
    shares = convertToShares(assets);
  }

  /// @inheritdoc IDreamMarginVault
  function previewMint(uint256 shares) public view returns (uint256 assets) {
    assets = LibPositionRisk.vaultAssetsUp(
      shares, totalSupply(), totalAssets(), _VIRTUAL_SHARES, _VIRTUAL_ASSETS
    );
  }

  /// @inheritdoc IDreamMarginVault
  function previewWithdraw(uint256 assets) public view returns (uint256 shares) {
    shares = LibPositionRisk.vaultSharesUp(
      assets, totalSupply(), totalAssets(), _VIRTUAL_SHARES, _VIRTUAL_ASSETS
    );
  }

  /// @inheritdoc IDreamMarginVault
  function previewRedeem(uint256 shares) public view returns (uint256 assets) {
    assets = convertToAssets(shares);
  }

  // -------------------------------------------------------------------------
  // ERC-4626 state transitions
  // -------------------------------------------------------------------------

  /// @inheritdoc IDreamMarginVault
  function deposit(uint256 assets, address receiver)
    external
    nonReentrant
    returns (uint256 shares)
  {
    _nonzeroAddress(receiver, "RECEIVER");
    _nonzeroAmount(assets);
    shares = previewDeposit(assets);
    if (shares == 0) revert LibDreamMarginErrors.QuantizedToZero(assets, _VIRTUAL_SHARES);

    _receiveExact(msg.sender, assets);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.internalCash += assets;
    _mintShares(self, receiver, shares);
    emit Deposit(msg.sender, receiver, assets, shares);
  }

  /// @inheritdoc IDreamMarginVault
  function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
    _nonzeroAddress(receiver, "RECEIVER");
    _nonzeroAmount(shares);
    assets = previewMint(shares);
    if (assets == 0) revert LibDreamMarginErrors.QuantizedToZero(shares, _VIRTUAL_ASSETS);

    _receiveExact(msg.sender, assets);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.internalCash += assets;
    _mintShares(self, receiver, shares);
    emit Deposit(msg.sender, receiver, assets, shares);
  }

  /// @inheritdoc IDreamMarginVault
  function withdraw(uint256 assets, address receiver, address owner)
    external
    nonReentrant
    returns (uint256 shares)
  {
    _nonzeroAddress(receiver, "RECEIVER");
    _nonzeroAddress(owner, "OWNER");
    _nonzeroAmount(assets);
    uint256 liquidity = availableLiquidity();
    if (assets > liquidity) revert LibDreamMarginErrors.InsufficientLiquidity(liquidity, assets);

    shares = previewWithdraw(assets);
    _exit(assets, shares, receiver, owner);
  }

  /// @inheritdoc IDreamMarginVault
  function redeem(uint256 shares, address receiver, address owner)
    external
    nonReentrant
    returns (uint256 assets)
  {
    _nonzeroAddress(receiver, "RECEIVER");
    _nonzeroAddress(owner, "OWNER");
    _nonzeroAmount(shares);
    assets = previewRedeem(shares);
    if (assets == 0) revert LibDreamMarginErrors.QuantizedToZero(shares, _VIRTUAL_ASSETS);
    uint256 liquidity = availableLiquidity();
    if (assets > liquidity) revert LibDreamMarginErrors.InsufficientLiquidity(liquidity, assets);

    _exit(assets, shares, receiver, owner);
  }

  // -------------------------------------------------------------------------
  // Credit and reserve views
  // -------------------------------------------------------------------------

  /// @inheritdoc IDreamMarginVault
  function availableLiquidity() public view returns (uint256 assets) {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    if (self.internalCash > self.lockedReserve) assets = self.internalCash - self.lockedReserve;
  }

  /// @inheritdoc IDreamMarginVault
  function internalCash() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().internalCash;
  }

  /// @inheritdoc IDreamMarginVault
  function performingDebt() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().performingDebt;
  }

  /// @inheritdoc IDreamMarginVault
  function collectibleInterest() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().collectibleInterest;
  }

  /// @inheritdoc IDreamMarginVault
  function debtIndexWad() public view returns (uint256 indexWad) {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    indexWad = LibPositionRisk.accrueDebtIndexUp(
      self.debtIndexWad, _ANNUAL_RATE_WAD, block.timestamp - self.lastAccrual
    );
  }

  /// @inheritdoc IDreamMarginVault
  function totalDebtShares() external view returns (uint256 shares) {
    shares = LibDreamMarginVaultStorage.get().totalDebtShares;
  }

  /// @inheritdoc IDreamMarginVault
  function protocolReserve() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().protocolReserve;
  }

  /// @inheritdoc IDreamMarginVault
  function lockedReserve() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().lockedReserve;
  }

  /// @inheritdoc IDreamMarginVault
  function protocolReserveShares() external view returns (uint256 shares) {
    shares = LibDreamMarginVaultStorage.get().protocolReserveShares;
  }

  /// @inheritdoc IDreamMarginVault
  function unaccountedSurplus() external view returns (uint256 assets) {
    uint256 balance = IERC20Minimal(_ASSET).balanceOf(address(this));
    uint256 cash = LibDreamMarginVaultStorage.get().internalCash;
    if (balance > cash) assets = balance - cash;
  }

  /// @inheritdoc IDreamMarginVault
  function realizedBadDebt() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().realizedBadDebt;
  }

  /// @inheritdoc IDreamMarginVault
  function recoveredBadDebt() external view returns (uint256 assets) {
    assets = LibDreamMarginVaultStorage.get().recoveredBadDebt;
  }

  /// @inheritdoc IDreamMarginVault
  function debtAssets(uint256 debtShares) public view returns (uint256 assets) {
    assets = LibPositionRisk.debtAssetsUp(debtShares, debtIndexWad());
  }

  // -------------------------------------------------------------------------
  // Controller-only credit and reserve transitions
  // -------------------------------------------------------------------------

  /// @inheritdoc IDreamMarginVault
  function accrueInterest() external onlyController returns (uint256 interestAccrued) {
    interestAccrued = _accrue();
  }

  /// @inheritdoc IDreamMarginVault
  function borrow(uint256 assets, address receiver)
    external
    nonReentrant
    onlyController
    returns (uint256 debtShares)
  {
    _nonzeroAddress(receiver, "RECEIVER");
    _nonzeroAmount(assets);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _accrue();
    uint256 liquidity = availableLiquidity();
    if (assets > liquidity) revert LibDreamMarginErrors.InsufficientLiquidity(liquidity, assets);

    uint256 oldReceivable = self.performingDebt + self.collectibleInterest;
    debtShares = LibPositionRisk.debtSharesUp(assets, self.debtIndexWad);
    self.totalDebtShares += debtShares;
    uint256 nextReceivable = LibPositionRisk.debtAssetsUp(self.totalDebtShares, self.debtIndexWad);
    uint256 receivableCreated = nextReceivable - oldReceivable;
    self.performingDebt += assets;
    self.collectibleInterest += receivableCreated - assets;
    self.internalCash -= assets;

    _sendExact(receiver, assets);
    emit Borrow(receiver, assets, debtShares);
  }

  /// @inheritdoc IDreamMarginVault
  function repay(uint256 debtShares, uint256 maxAssets)
    external
    nonReentrant
    onlyController
    returns (uint256 assetsRepaid, uint256 sharesRepaid)
  {
    _nonzeroAmount(debtShares);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _accrue();
    uint256 outstandingShares = self.totalDebtShares;
    if (debtShares > outstandingShares) {
      revert LibDreamMarginErrors.InsufficientDebtShares(outstandingShares, debtShares);
    }

    uint256 oldReceivable = self.performingDebt + self.collectibleInterest;
    uint256 remainingShares = outstandingShares - debtShares;
    uint256 nextReceivable =
      remainingShares == 0 ? 0 : LibPositionRisk.debtAssetsUp(remainingShares, self.debtIndexWad);
    assetsRepaid = oldReceivable - nextReceivable;
    if (assetsRepaid > maxAssets) {
      revert LibDreamMarginErrors.RepaymentLimitExceeded(assetsRepaid, maxAssets);
    }

    _receiveExact(msg.sender, assetsRepaid);
    self.internalCash += assetsRepaid;
    self.totalDebtShares = remainingShares;
    _reduceReceivable(self, assetsRepaid);
    sharesRepaid = debtShares;
    emit Repay(assetsRepaid, debtShares);
  }

  /// @inheritdoc IDreamMarginVault
  function writeOff(uint256 debtShares)
    external
    nonReentrant
    onlyController
    returns (uint256 assetsWrittenOff, uint256 reserveUsed)
  {
    _nonzeroAmount(debtShares);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _accrue();
    uint256 outstandingShares = self.totalDebtShares;
    if (debtShares > outstandingShares) {
      revert LibDreamMarginErrors.InsufficientDebtShares(outstandingShares, debtShares);
    }

    uint256 assetsBeforeLoss = self.internalCash + self.performingDebt + self.collectibleInterest;
    uint256 remainingShares = outstandingShares - debtShares;
    uint256 nextReceivable =
      remainingShares == 0 ? 0 : LibPositionRisk.debtAssetsUp(remainingShares, self.debtIndexWad);
    assetsWrittenOff = self.performingDebt + self.collectibleInterest - nextReceivable;

    uint256 reserveSharesBurned;
    (reserveUsed, reserveSharesBurned) = _consumeReserve(self, assetsWrittenOff, assetsBeforeLoss);

    self.totalDebtShares = remainingShares;
    _reduceReceivable(self, assetsWrittenOff);
    self.realizedBadDebt += assetsWrittenOff;
    emit DebtWrittenOff(assetsWrittenOff, reserveUsed, reserveSharesBurned);
  }

  /// @inheritdoc IDreamMarginVault
  function settleDebt(uint256 debtShares, uint256 maxRecoveryAssets)
    external
    nonReentrant
    onlyController
    returns (uint256 assetsRepaid, uint256 assetsWrittenOff, uint256 reserveUsed)
  {
    _nonzeroAmount(debtShares);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _accrue();
    uint256 outstandingShares = self.totalDebtShares;
    if (debtShares > outstandingShares) {
      revert LibDreamMarginErrors.InsufficientDebtShares(outstandingShares, debtShares);
    }

    uint256 oldReceivable = self.performingDebt + self.collectibleInterest;
    uint256 assetsBeforeLoss = self.internalCash + oldReceivable;
    uint256 remainingShares = outstandingShares - debtShares;
    uint256 nextReceivable =
      remainingShares == 0 ? 0 : LibPositionRisk.debtAssetsUp(remainingShares, self.debtIndexWad);
    uint256 positionReceivable = oldReceivable - nextReceivable;
    assetsRepaid = FixedPointMathLib.min(maxRecoveryAssets, positionReceivable);
    if (assetsRepaid != 0) {
      _receiveExact(msg.sender, assetsRepaid);
      self.internalCash += assetsRepaid;
    }
    self.totalDebtShares = remainingShares;
    _reduceReceivable(self, positionReceivable);
    assetsWrittenOff = positionReceivable - assetsRepaid;
    uint256 reserveSharesBurned;
    (reserveUsed, reserveSharesBurned) = _consumeReserve(self, assetsWrittenOff, assetsBeforeLoss);
    self.realizedBadDebt += assetsWrittenOff;
    emit DebtSettled(debtShares, assetsRepaid, assetsWrittenOff, reserveUsed, reserveSharesBurned);
  }

  /// @inheritdoc IDreamMarginVault
  function fundReserve(uint256 assets)
    external
    nonReentrant
    onlyController
    returns (uint256 reserveShares)
  {
    _nonzeroAmount(assets);
    reserveShares = previewDeposit(assets);
    if (reserveShares == 0) {
      revert LibDreamMarginErrors.QuantizedToZero(assets, _VIRTUAL_SHARES);
    }

    _receiveExact(msg.sender, assets);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.internalCash += assets;
    self.lockedReserve += assets;
    self.protocolReserve += assets;
    self.protocolReserveShares += reserveShares;
    _mintShares(self, address(this), reserveShares);
    emit ReserveFunded(assets, reserveShares);
  }

  /// @inheritdoc IDreamMarginVault
  function withdrawReserve(uint256 assets, address receiver)
    external
    nonReentrant
    onlyController
    returns (uint256 reserveSharesBurned)
  {
    _nonzeroAmount(assets);
    _nonzeroAddress(receiver, "RESERVE_RECEIVER");
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _accrue();

    uint256 debtShares = self.totalDebtShares;
    uint256 unrecoveredLoss = self.realizedBadDebt > self.recoveredBadDebt
      ? self.realizedBadDebt - self.recoveredBadDebt
      : 0;
    if (debtShares != 0 || unrecoveredLoss != 0) {
      revert LibDreamMarginErrors.ReserveWithdrawalBlocked(debtShares, unrecoveredLoss);
    }

    uint256 assetsBefore = self.internalCash;
    uint256 reserveCapacity = LibPositionRisk.vaultAssetsDown(
      self.protocolReserveShares, self.totalSupply, assetsBefore, _VIRTUAL_SHARES, _VIRTUAL_ASSETS
    );
    uint256 available = FixedPointMathLib.min(self.protocolReserve, reserveCapacity);
    available = FixedPointMathLib.min(available, assetsBefore);
    if (available < self.protocolReserve && self.protocolReserveShares != 0) {
      uint256 partialCapacity = LibPositionRisk.vaultAssetsDown(
        self.protocolReserveShares - 1,
        self.totalSupply,
        assetsBefore,
        _VIRTUAL_SHARES,
        _VIRTUAL_ASSETS
      );
      available = FixedPointMathLib.min(available, partialCapacity);
    }
    if (assets > available) {
      revert LibDreamMarginErrors.InsufficientLiquidity(available, assets);
    }

    reserveSharesBurned = assets == self.protocolReserve
      ? self.protocolReserveShares
      : LibPositionRisk.vaultSharesUp(
        assets, self.totalSupply, assetsBefore, _VIRTUAL_SHARES, _VIRTUAL_ASSETS
      );
    self.protocolReserve -= assets;
    self.lockedReserve -= assets;
    self.protocolReserveShares -= reserveSharesBurned;
    self.internalCash -= assets;
    _burnShares(self, address(this), reserveSharesBurned);
    _sendExact(receiver, assets);
    emit ReserveWithdrawn(receiver, assets, reserveSharesBurned);
  }

  /// @inheritdoc IDreamMarginVault
  function recordRecovery(uint256 assets) external nonReentrant onlyController {
    _nonzeroAmount(assets);
    _receiveExact(msg.sender, assets);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.internalCash += assets;
    self.recoveredBadDebt += assets;
    emit RecoveryRecorded(assets);
  }

  // -------------------------------------------------------------------------
  // Internal accounting
  // -------------------------------------------------------------------------

  /// @notice Completes a cash-limited exit after caller-specific checks.
  /// @param assets Exact assets transferred.
  /// @param shares Exact shares burned.
  /// @param receiver Account receiving assets.
  /// @param owner Account whose shares are burned.
  function _exit(uint256 assets, uint256 shares, address receiver, address owner) private {
    if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    _burnShares(self, owner, shares);
    self.internalCash -= assets;
    _sendExact(receiver, assets);
    emit Withdraw(msg.sender, receiver, owner, assets, shares);
  }

  /// @notice Advances stored interest to the current timestamp, rounded up for the vault.
  /// @return interestAccrued Newly recorded collectible interest.
  function _accrue() private returns (uint256 interestAccrued) {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    uint256 previousIndexWad = self.debtIndexWad;
    uint256 nextIndexWad = debtIndexWad();
    uint256 oldReceivable = self.performingDebt + self.collectibleInterest;
    uint256 nextReceivable = self.totalDebtShares == 0
      ? 0
      : LibPositionRisk.debtAssetsUp(self.totalDebtShares, nextIndexWad);
    if (nextReceivable > oldReceivable) {
      interestAccrued = nextReceivable - oldReceivable;
      self.collectibleInterest += interestAccrued;
    }
    self.debtIndexWad = nextIndexWad;
    self.lastAccrual = _timestamp40();
    emit InterestAccrued(previousIndexWad, nextIndexWad, interestAccrued);
  }

  /// @notice Returns stored principal and interest including elapsed projected interest.
  /// @param self Vault namespace.
  /// @return receivable Current collectible receivable rounded up.
  function _projectedReceivable(LibDreamMarginVaultStorage.State storage self)
    private
    view
    returns (uint256 receivable)
  {
    if (self.totalDebtShares == 0) return 0;
    receivable = LibPositionRisk.debtAssetsUp(self.totalDebtShares, debtIndexWad());
  }

  /// @notice Removes a receivable amount from interest first, then principal.
  /// @param self Vault namespace.
  /// @param assets Receivable reduction in asset native units.
  function _reduceReceivable(LibDreamMarginVaultStorage.State storage self, uint256 assets)
    private
  {
    uint256 interest = self.collectibleInterest;
    if (assets <= interest) {
      self.collectibleInterest = interest - assets;
    } else {
      self.collectibleInterest = 0;
      self.performingDebt -= assets - interest;
    }
  }

  /// @notice Applies funded junior reserve capacity to a realized loss.
  /// @param self Vault namespace.
  /// @param lossAssets Receivable shortfall in asset native units.
  /// @param assetsBeforeLoss Vault assets immediately before loss recognition.
  /// @return reserveUsed Reserve assets allocated to the loss.
  /// @return reserveSharesBurned Junior reserve shares burned.
  function _consumeReserve(
    LibDreamMarginVaultStorage.State storage self,
    uint256 lossAssets,
    uint256 assetsBeforeLoss
  ) private returns (uint256 reserveUsed, uint256 reserveSharesBurned) {
    uint256 reserveCapacity = LibPositionRisk.vaultAssetsDown(
        self.protocolReserveShares,
        self.totalSupply,
        assetsBeforeLoss,
        _VIRTUAL_SHARES,
        _VIRTUAL_ASSETS
      );
    reserveUsed = FixedPointMathLib.min(lossAssets, self.protocolReserve);
    reserveUsed = FixedPointMathLib.min(reserveUsed, reserveCapacity);
    if (reserveUsed == 0) return (0, 0);

    reserveSharesBurned = reserveUsed == self.protocolReserve
      ? self.protocolReserveShares
      : LibPositionRisk.vaultSharesUp(
        reserveUsed, self.totalSupply, assetsBeforeLoss, _VIRTUAL_SHARES, _VIRTUAL_ASSETS
      );
    self.protocolReserve -= reserveUsed;
    self.lockedReserve -= reserveUsed;
    self.protocolReserveShares -= reserveSharesBurned;
    _burnShares(self, address(this), reserveSharesBurned);
  }

  /// @notice Mints shares and emits the ERC-20 transfer event.
  /// @param self Vault namespace.
  /// @param receiver Account receiving shares.
  /// @param shares Shares minted.
  function _mintShares(
    LibDreamMarginVaultStorage.State storage self,
    address receiver,
    uint256 shares
  ) private {
    self.totalSupply += shares;
    self.balanceOf[receiver] += shares;
    emit Transfer(address(0), receiver, shares);
  }

  /// @notice Burns shares after verifying the owner's balance.
  /// @param self Vault namespace.
  /// @param owner Account losing shares.
  /// @param shares Shares burned.
  function _burnShares(LibDreamMarginVaultStorage.State storage self, address owner, uint256 shares)
    private
  {
    uint256 available = self.balanceOf[owner];
    if (shares > available) {
      revert LibDreamMarginErrors.InsufficientVaultShares(available, shares);
    }
    self.balanceOf[owner] = available - shares;
    self.totalSupply -= shares;
    emit Transfer(owner, address(0), shares);
  }

  /// @notice Moves shares after checking nonzero receiver and owner balance.
  /// @param owner Account losing shares.
  /// @param receiver Account receiving shares.
  /// @param shares Shares moved.
  function _transferShares(address owner, address receiver, uint256 shares) private {
    _nonzeroAddress(receiver, "RECEIVER");
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    uint256 available = self.balanceOf[owner];
    if (shares > available) {
      revert LibDreamMarginErrors.InsufficientVaultShares(available, shares);
    }
    self.balanceOf[owner] = available - shares;
    self.balanceOf[receiver] += shares;
    emit Transfer(owner, receiver, shares);
  }

  /// @notice Decrements a finite share allowance, preserving infinite approval.
  /// @param owner Share owner.
  /// @param spender Account consuming allowance.
  /// @param shares Shares authorized for movement or burning.
  function _spendAllowance(address owner, address spender, uint256 shares) private {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    uint256 available = self.allowance[owner][spender];
    if (available != type(uint256).max) {
      if (shares > available) {
        revert LibDreamMarginErrors.InsufficientShareAllowance(available, shares);
      }
      self.allowance[owner][spender] = available - shares;
      emit Approval(owner, spender, available - shares);
    }
  }

  /// @notice Pulls an exact asset amount and rejects fee-on-transfer or rebasing deltas.
  /// @param sender Account supplying assets.
  /// @param assets Exact assets expected.
  function _receiveExact(address sender, uint256 assets) private {
    uint256 balanceBefore = IERC20Minimal(_ASSET).balanceOf(address(this));
    SafeTransferLib.safeTransferFrom(_ASSET, sender, address(this), assets);
    uint256 balanceAfter = IERC20Minimal(_ASSET).balanceOf(address(this));
    uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
    if (received != assets) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(_ASSET, assets, received);
    }
  }

  /// @notice Sends an exact asset amount and rejects fee-on-transfer or rebasing deltas.
  /// @param receiver Account receiving assets.
  /// @param assets Exact assets expected.
  function _sendExact(address receiver, uint256 assets) private {
    uint256 vaultBefore = IERC20Minimal(_ASSET).balanceOf(address(this));
    uint256 receiverBefore = IERC20Minimal(_ASSET).balanceOf(receiver);
    SafeTransferLib.safeTransfer(_ASSET, receiver, assets);
    uint256 vaultAfter = IERC20Minimal(_ASSET).balanceOf(address(this));
    uint256 receiverAfter = IERC20Minimal(_ASSET).balanceOf(receiver);
    uint256 spent = vaultBefore >= vaultAfter ? vaultBefore - vaultAfter : 0;
    uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
    if (spent != assets) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(_ASSET, assets, spent);
    }
    if (received != assets) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(_ASSET, assets, received);
    }
  }

  /// @notice Rejects a zero address with a field identifier.
  /// @param account Address checked.
  /// @param field Identifier of the address role.
  function _nonzeroAddress(address account, bytes32 field) private pure {
    if (account == address(0)) revert LibDreamMarginErrors.ZeroAddress(field);
  }

  /// @notice Rejects a zero amount.
  /// @param amount Amount checked.
  function _nonzeroAmount(uint256 amount) private pure {
    if (amount == 0) revert LibDreamMarginErrors.ZeroAmount(amount);
  }

  /// @notice Narrows the current timestamp only after proving the storage bound.
  /// @return timestamp Current timestamp as an explicitly bounded forty-bit value.
  function _timestamp40() private view returns (uint40 timestamp) {
    // Timestamp manipulation cannot approach the forty-bit representational bound.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > type(uint40).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("TIMESTAMP", block.timestamp, type(uint40).max);
    }
    // The preceding bound check proves this narrowing conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    timestamp = uint40(block.timestamp);
  }
}

// forge-lint: disable-end(reentrancy-events)
