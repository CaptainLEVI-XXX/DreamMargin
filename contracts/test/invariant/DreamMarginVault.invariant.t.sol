// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin vault accounting invariant
/// @author DreamMargin contributors
/// @notice Reconciles cash, receivables, shares, reserve, and losses across arbitrary actions.
/// @dev The handler is the immutable controller and sole ordinary LP to keep ownership enumerable.

import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

// The handler deliberately advances time and invokes return-valued actions for their state effects.
// forge-lint: disable-start(unsafe-cheatcode, unused-return)

/// @notice Performs bounded successful vault actions for invariant exploration.
contract DreamMarginVaultHandler is Test {
  /// @notice Six-decimal collateral used by the state machine.
  MockERC20 public immutable ASSET;

  /// @notice Vault controlled by this handler.
  DreamMarginVault public immutable VAULT;

  /// @notice Number of successful deposits.
  uint256 public deposits;

  /// @notice Number of successful borrows.
  uint256 public borrows;

  /// @notice Number of successful debt reductions.
  uint256 public debtReductions;

  /// @notice Creates a fresh vault with a named ten-percent test financing rate.
  constructor() {
    ASSET = new MockERC20("Invariant USD", "iUSD", 6);
    VAULT = new DreamMarginVault(address(ASSET), address(this), 0.1e18);
    ASSET.approve(address(VAULT), type(uint256).max);
  }

  /// @notice Deposits a bounded positive asset amount.
  /// @param seed Fuzzed amount seed.
  function deposit(uint256 seed) external {
    uint256 assets = seed % 1_000_000_000 + 1;
    ASSET.mint(address(this), assets);
    if (VAULT.previewDeposit(assets) == 0) return;
    VAULT.deposit(assets, address(this));
    ++deposits;
  }

  /// @notice Borrows a bounded positive fraction of available liquidity.
  /// @param seed Fuzzed amount seed.
  function borrow(uint256 seed) external {
    uint256 liquidity = VAULT.availableLiquidity();
    if (liquidity == 0) return;
    uint256 assets = seed % liquidity + 1;
    VAULT.borrow(assets, address(this));
    ++borrows;
  }

  /// @notice Repays a bounded positive fraction of outstanding debt shares.
  /// @param seed Fuzzed share seed.
  function repay(uint256 seed) external {
    uint256 outstanding = VAULT.totalDebtShares();
    if (outstanding == 0) return;
    uint256 shares = seed % outstanding + 1;
    ASSET.mint(address(this), VAULT.debtAssets(shares));
    VAULT.repay(shares, type(uint256).max);
    ++debtReductions;
  }

  /// @notice Writes off a bounded positive fraction of outstanding debt shares.
  /// @param seed Fuzzed share seed.
  function writeOff(uint256 seed) external {
    uint256 outstanding = VAULT.totalDebtShares();
    if (outstanding == 0) return;
    VAULT.writeOff(seed % outstanding + 1);
    ++debtReductions;
  }

  /// @notice Funds a bounded positive amount of non-redeemable reserve capital.
  /// @param seed Fuzzed amount seed.
  function fundReserve(uint256 seed) external {
    uint256 assets = seed % 100_000_000 + 1;
    ASSET.mint(address(this), assets);
    if (VAULT.previewDeposit(assets) == 0) return;
    VAULT.fundReserve(assets);
  }

  /// @notice Records a bounded positive post-write-off recovery.
  /// @param seed Fuzzed amount seed.
  function recover(uint256 seed) external {
    uint256 assets = seed % 100_000_000 + 1;
    ASSET.mint(address(this), assets);
    VAULT.recordRecovery(assets);
  }

  /// @notice Redeems a bounded positive amount of immediately cash-backed shares.
  /// @param seed Fuzzed share seed.
  function redeem(uint256 seed) external {
    uint256 maximum = VAULT.maxRedeem(address(this));
    if (maximum == 0) return;
    uint256 minimum = VAULT.previewWithdraw(1);
    if (minimum > maximum) return;
    uint256 shares = minimum + seed % (maximum - minimum + 1);
    VAULT.redeem(shares, address(this), address(this));
  }

  /// @notice Advances time and immediately stores the projected debt interest.
  /// @param seed Fuzzed elapsed-time seed.
  function elapse(uint256 seed) external {
    vm.warp(block.timestamp + seed % 30 days);
    VAULT.accrueInterest();
  }
}

/// @notice Asserts the vault accounting identity after every arbitrary handler sequence.
contract DreamMarginVaultInvariantTest is StdInvariant, Test {
  /// @notice Handler targeted by Foundry's invariant engine.
  DreamMarginVaultHandler private _handler;

  /// @notice Vault under invariant testing.
  DreamMarginVault private _vault;

  /// @notice Collateral backing the vault.
  MockERC20 private _asset;

  /// @notice Deploys the handler and targets all of its external action selectors.
  function setUp() external {
    _handler = new DreamMarginVaultHandler();
    _vault = _handler.VAULT();
    _asset = _handler.ASSET();
    targetContract(address(_handler));
  }

  /// @notice DM-I10: reported assets equal cash plus performing principal and stored interest.
  function invariant_I10_vaultAccounting() external view {
    assertEq(
      _vault.totalAssets(),
      _vault.internalCash() + _vault.performingDebt() + _vault.collectibleInterest()
    );
    assertEq(_asset.balanceOf(address(_vault)), _vault.internalCash());
  }

  /// @notice Proves reserve cash and shares remain funded, locked, and non-redeemable.
  function invariant_reserveBackingAndShareSupply() external view {
    assertEq(_vault.lockedReserve(), _vault.protocolReserve());
    assertLe(_vault.protocolReserve(), _vault.internalCash());
    assertEq(_vault.balanceOf(address(_vault)), _vault.protocolReserveShares());
    assertEq(
      _vault.totalSupply(), _vault.balanceOf(address(_handler)) + _vault.balanceOf(address(_vault))
    );
  }

  /// @notice Proves zero aggregate debt shares never leave a collectible receivable behind.
  function invariant_zeroDebtHasNoReceivable() external view {
    if (_vault.totalDebtShares() == 0) {
      assertEq(_vault.performingDebt(), 0);
      assertEq(_vault.collectibleInterest(), 0);
    }
  }

  /// @notice Proves ordinary synchronous liquidity excludes every locked reserve asset.
  function invariant_availableLiquidityIsCashMinusReserve() external view {
    assertEq(_vault.availableLiquidity(), _vault.internalCash() - _vault.lockedReserve());
  }
}

// forge-lint: disable-end(unsafe-cheatcode, unused-return)
