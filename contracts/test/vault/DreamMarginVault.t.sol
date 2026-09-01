// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin vault tests
/// @author DreamMargin contributors
/// @notice Verifies ERC-4626, credit, reserve, loss, and hostile-token behavior.
/// @dev Named fixtures are test hypotheses; no production risk parameter is implied.

import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {MockCallbackERC20, MockFeeOnTransferERC20} from "test/mock/AdversarialERC20.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

// These tests intentionally exercise delegated ERC-20 movement, ignored values on expected-revert
// calls, and fixed-width error selectors whose truncation is the behavior under test.
// forge-lint: disable-start(arbitrary-send-erc20, erc20-unchecked-transfer, unsafe-typecast, unused-return)

/// @notice Exercises one six-decimal vault and fresh hostile-token vaults.
contract DreamMarginVaultTest is Test {
  /// @notice One whole six-decimal collateral token.
  uint256 private constant _UNIT = 1e6;

  /// @notice Named conservative fixture for a ten-percent simple annual rate.
  uint256 private constant _TEST_ANNUAL_RATE_WAD = 0.1e18;

  /// @notice Stable timestamp used to make accrual assertions deterministic.
  uint256 private constant _START_TIME = 1_000_000;

  /// @notice One fixed year used by the simple financing model.
  uint256 private constant _YEAR = 365 days;

  /// @notice Primary LP account.
  address private constant _ALICE = address(0xA11CE);

  /// @notice Secondary LP and delegated spender.
  address private constant _BOB = address(0xB0B);

  /// @notice Standard six-decimal test collateral.
  MockERC20 private _asset;

  /// @notice Vault whose immutable controller is this test contract.
  DreamMarginVault private _vault;

  /// @notice Deploys and funds a clean fixture before each test.
  function setUp() external {
    vm.warp(_START_TIME);
    _asset = new MockERC20("Test USD", "tUSD", 6);
    _vault = new DreamMarginVault(address(_asset), address(this), _TEST_ANNUAL_RATE_WAD);

    _asset.mint(_ALICE, 10_000 * _UNIT);
    _asset.mint(_BOB, 10_000 * _UNIT);
    _asset.mint(address(this), 10_000 * _UNIT);
    vm.prank(_ALICE);
    _asset.approve(address(_vault), type(uint256).max);
    vm.prank(_BOB);
    _asset.approve(address(_vault), type(uint256).max);
    _asset.approve(address(_vault), type(uint256).max);
  }

  // -------------------------------------------------------------------------
  // Deployment and ERC-20 shares
  // -------------------------------------------------------------------------

  /// @notice Exposes immutable bindings and six additional share decimals.
  function test_deploymentBindsAssetControllerAndRate() external view {
    assertEq(_vault.name(), "DreamMargin Vault Share");
    assertEq(_vault.symbol(), "dmSHARE");
    assertEq(_vault.decimals(), 12);
    assertEq(_vault.asset(), address(_asset));
    assertEq(_vault.controller(), address(this));
    assertEq(_vault.annualRateWad(), _TEST_ANNUAL_RATE_WAD);
    assertEq(_vault.debtIndexWad(), 1e18);
  }

  /// @notice Rejects zero immutable dependencies and unsupported collateral precision.
  function test_constructorRejectsInvalidDependencies() external {
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.ZeroAddress.selector, bytes32("ASSET"))
    );
    new DreamMarginVault(address(0), address(this), 0);

    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.ZeroAddress.selector, bytes32("CONTROLLER"))
    );
    new DreamMarginVault(address(_asset), address(0), 0);

    MockERC20 excessiveDecimals = new MockERC20("Too Precise", "TOO", 19);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.UnsupportedDecimals.selector, uint8(19), uint8(18)
      )
    );
    new DreamMarginVault(address(excessiveDecimals), address(this), 0);
  }

  /// @notice Transfers shares and consumes finite delegated allowance exactly.
  function test_shareTransfersAndAllowances() external {
    uint256 depositedShares = _depositAs(_ALICE, 100 * _UNIT);
    vm.prank(_ALICE);
    assertTrue(_vault.approve(_BOB, depositedShares / 2));

    vm.prank(_BOB);
    assertTrue(_vault.transferFrom(_ALICE, _BOB, depositedShares / 2));
    assertEq(_vault.balanceOf(_ALICE), depositedShares / 2);
    assertEq(_vault.balanceOf(_BOB), depositedShares / 2);
    assertEq(_vault.allowance(_ALICE, _BOB), 0);

    vm.prank(_BOB);
    assertTrue(_vault.transfer(_ALICE, depositedShares / 4));
    assertEq(_vault.balanceOf(_ALICE), depositedShares * 3 / 4);
  }

  /// @notice Infinite delegated allowance is preserved across share movement.
  function test_infiniteShareAllowanceIsNotDecremented() external {
    uint256 shares = _depositAs(_ALICE, 10 * _UNIT);
    vm.prank(_ALICE);
    _vault.approve(_BOB, type(uint256).max);
    vm.prank(_BOB);
    _vault.transferFrom(_ALICE, _BOB, shares);
    assertEq(_vault.allowance(_ALICE, _BOB), type(uint256).max);
  }

  // -------------------------------------------------------------------------
  // ERC-4626 deposits and exits
  // -------------------------------------------------------------------------

  /// @notice Gives the first depositor the six-decimal virtual share offset.
  function test_firstDepositUsesVirtualShareOffset() external {
    uint256 shares = _depositAs(_ALICE, 1 * _UNIT);
    assertEq(shares, 1e12);
    assertEq(_vault.totalSupply(), 1e12);
    assertEq(_vault.totalAssets(), 1 * _UNIT);
    assertEq(_vault.convertToAssets(shares), 1 * _UNIT);
  }

  /// @notice Mints exact shares with assets rounded up, then withdraws exact assets.
  function test_mintAndWithdrawHonorOppositeRounding() external {
    vm.prank(_ALICE);
    uint256 assets = _vault.mint(1_000_001, _ALICE);
    assertEq(assets, 2);
    assertEq(_vault.balanceOf(_ALICE), 1_000_001);

    vm.prank(_ALICE);
    uint256 sharesBurned = _vault.withdraw(1, _ALICE, _ALICE);
    assertEq(sharesBurned, _vault.previewWithdraw(1));
    assertEq(_vault.internalCash(), 1);
  }

  /// @notice Redeems shares for assets rounded down and burns the exact input shares.
  function test_redeemPaysRoundedDownAssets() external {
    uint256 shares = _depositAs(_ALICE, 100 * _UNIT);
    vm.prank(_ALICE);
    uint256 assets = _vault.redeem(shares / 3, _ALICE, _ALICE);
    assertEq(assets, 100 * _UNIT / 3);
    assertEq(_vault.balanceOf(_ALICE), shares - shares / 3);
  }

  /// @notice Allows a spender to withdraw only after consuming owner share allowance.
  function test_delegatedWithdrawConsumesShareAllowance() external {
    _depositAs(_ALICE, 100 * _UNIT);
    uint256 shares = _vault.previewWithdraw(10 * _UNIT);
    vm.prank(_ALICE);
    _vault.approve(_BOB, shares);

    vm.prank(_BOB);
    _vault.withdraw(10 * _UNIT, _BOB, _ALICE);
    assertEq(_asset.balanceOf(_BOB), 10_010 * _UNIT);
    assertEq(_vault.allowance(_ALICE, _BOB), 0);
  }

  /// @notice Rejects zero-value actions and zero share or asset results.
  function test_zeroValueVaultActionsRevert() external {
    vm.startPrank(_ALICE);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ZeroAmount.selector, 0));
    _vault.deposit(0, _ALICE);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ZeroAmount.selector, 0));
    _vault.mint(0, _ALICE);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ZeroAmount.selector, 0));
    _vault.withdraw(0, _ALICE, _ALICE);
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ZeroAmount.selector, 0));
    _vault.redeem(0, _ALICE, _ALICE);
    vm.stopPrank();
  }

  /// @notice Keeps direct donations outside reported assets and share conversion.
  function test_directDonationDoesNotChangeAccountingOrQuotes() external {
    _depositAs(_ALICE, 100 * _UNIT);
    uint256 quoteBefore = _vault.previewDeposit(10 * _UNIT);

    vm.prank(_BOB);
    _asset.transfer(address(_vault), 1_000 * _UNIT);

    assertEq(_vault.totalAssets(), 100 * _UNIT);
    assertEq(_vault.internalCash(), 100 * _UNIT);
    assertEq(_vault.unaccountedSurplus(), 1_000 * _UNIT);
    assertEq(_vault.previewDeposit(10 * _UNIT), quoteBefore);
  }

  /// @notice Prevents an attacker donation from reducing a later depositor's shares.
  function test_firstDepositorDonationCannotStealVictimDeposit() external {
    _depositAs(_ALICE, 1);
    vm.prank(_ALICE);
    _asset.transfer(address(_vault), 1_000 * _UNIT);
    uint256 expected = _vault.previewDeposit(100 * _UNIT);

    uint256 received = _depositAs(_BOB, 100 * _UNIT);
    assertEq(received, expected);
    assertEq(_vault.convertToAssets(received), 100 * _UNIT);
  }

  // -------------------------------------------------------------------------
  // Credit, interest, and liquidity
  // -------------------------------------------------------------------------

  /// @notice Moves cash out while replacing it with an equal performing receivable.
  function test_borrowCreatesDebtWithoutChangingTotalAssets() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 controllerBefore = _asset.balanceOf(address(this));

    uint256 debtShares = _vault.borrow(600 * _UNIT, address(this));

    assertEq(debtShares, 600 * _UNIT);
    assertEq(_asset.balanceOf(address(this)), controllerBefore + 600 * _UNIT);
    assertEq(_vault.internalCash(), 400 * _UNIT);
    assertEq(_vault.performingDebt(), 600 * _UNIT);
    assertEq(_vault.totalAssets(), 1_000 * _UNIT);
    assertEq(_vault.availableLiquidity(), 400 * _UNIT);
  }

  /// @notice Caps synchronous exits at accounted cash while debt is illiquid.
  function test_maxExitFunctionsAreCashLimited() external {
    uint256 ownerShares = _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.borrow(600 * _UNIT, address(this));

    assertEq(_vault.maxWithdraw(_ALICE), 400 * _UNIT);
    assertEq(_vault.maxRedeem(_ALICE), _vault.convertToShares(400 * _UNIT));
    assertLt(_vault.maxRedeem(_ALICE), ownerShares);

    vm.prank(_ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InsufficientLiquidity.selector, 400 * _UNIT, 401 * _UNIT
      )
    );
    _vault.withdraw(401 * _UNIT, _ALICE, _ALICE);
  }

  /// @notice Projects elapsed interest in views and stores it on controller accrual.
  function test_interestAccruesAtImmutableSimpleRate() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.borrow(400 * _UNIT, address(this));
    vm.warp(_START_TIME + _YEAR);

    assertEq(_vault.debtIndexWad(), 1.1e18);
    assertEq(_vault.debtAssets(400 * _UNIT), 440 * _UNIT);
    assertEq(_vault.totalAssets(), 1_040 * _UNIT);
    assertEq(_vault.collectibleInterest(), 0);

    uint256 accrued = _vault.accrueInterest();
    assertEq(accrued, 40 * _UNIT);
    assertEq(_vault.collectibleInterest(), 40 * _UNIT);
    assertEq(_vault.totalAssets(), 1_040 * _UNIT);
  }

  /// @notice Applies partial repayment to interest before reducing principal.
  function test_partialRepaymentIsInterestFirst() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.borrow(400 * _UNIT, address(this));
    vm.warp(_START_TIME + _YEAR);

    (uint256 assetsRepaid, uint256 sharesRepaid) = _vault.repay(100 * _UNIT, 110 * _UNIT);

    assertEq(assetsRepaid, 110 * _UNIT);
    assertEq(sharesRepaid, 100 * _UNIT);
    assertEq(_vault.totalDebtShares(), 300 * _UNIT);
    assertEq(_vault.collectibleInterest(), 0);
    assertEq(_vault.performingDebt(), 330 * _UNIT);
    assertEq(_vault.internalCash(), 710 * _UNIT);
  }

  /// @notice Clears the final debt share without leaving a rounded receivable.
  function test_fullRepaymentClearsReceivableExactly() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 shares = _vault.borrow(333 * _UNIT + 1, address(this));
    (uint256 repaid, uint256 retired) = _vault.repay(shares, type(uint256).max);

    assertEq(repaid, 333 * _UNIT + 1);
    assertEq(retired, shares);
    assertEq(_vault.totalDebtShares(), 0);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_vault.collectibleInterest(), 0);
    assertEq(_vault.totalAssets(), 1_000 * _UNIT);
  }

  /// @notice Reverts atomically when exact repayment exceeds the controller limit.
  function test_repaymentLimitProtectsController() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 shares = _vault.borrow(100 * _UNIT, address(this));

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.RepaymentLimitExceeded.selector, 100 * _UNIT, 99 * _UNIT
      )
    );
    _vault.repay(shares, 99 * _UNIT);
    assertEq(_vault.totalDebtShares(), shares);
    assertEq(_vault.performingDebt(), 100 * _UNIT);
  }

  /// @notice Restricts every credit-accounting mutation to the immutable controller.
  function test_nonControllerCannotMutateCredit() external {
    vm.startPrank(_ALICE);
    bytes memory expected =
      abi.encodeWithSelector(LibDreamMarginErrors.NotController.selector, _ALICE, address(this));
    vm.expectRevert(expected);
    _vault.borrow(1, _ALICE);
    vm.expectRevert(expected);
    _vault.repay(1, 1);
    vm.expectRevert(expected);
    _vault.writeOff(1);
    vm.expectRevert(expected);
    _vault.settleDebt(1, 0);
    vm.expectRevert(expected);
    _vault.fundReserve(1);
    vm.expectRevert(expected);
    _vault.recordRecovery(1);
    vm.stopPrank();
  }

  // -------------------------------------------------------------------------
  // Reserve, loss, and recovery
  // -------------------------------------------------------------------------

  /// @notice Locks funded reserve cash and mints shares only to the vault itself.
  function test_fundedReserveIsNotOrdinaryWithdrawableLiquidity() external {
    _depositAs(_ALICE, 100 * _UNIT);
    uint256 reserveShares = _vault.fundReserve(100 * _UNIT);

    assertEq(_vault.protocolReserve(), 100 * _UNIT);
    assertEq(_vault.protocolReserveShares(), reserveShares);
    assertEq(_vault.balanceOf(address(_vault)), reserveShares);
    assertEq(_vault.totalAssets(), 200 * _UNIT);
    assertEq(_vault.availableLiquidity(), 100 * _UNIT);
    assertEq(_vault.maxWithdraw(_ALICE), 100 * _UNIT);
  }

  /// @notice Burns junior reserve shares so a covered loss preserves senior LP value.
  function test_reserveSharesAbsorbCoveredWriteOff() external {
    uint256 aliceShares = _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.fundReserve(100 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));
    uint256 aliceValueBefore = _vault.convertToAssets(aliceShares);

    (uint256 writtenOff, uint256 reserveUsed) = _vault.writeOff(debtShares * 2 / 5);

    assertEq(writtenOff, 80 * _UNIT);
    assertEq(reserveUsed, 80 * _UNIT);
    assertEq(_vault.protocolReserve(), 20 * _UNIT);
    assertEq(_vault.realizedBadDebt(), 80 * _UNIT);
    assertEq(_vault.convertToAssets(aliceShares), aliceValueBefore);
  }

  /// @notice Applies only funded reserve capacity before passing excess loss to senior LPs.
  function test_excessWriteOffReducesSeniorShareValueOnce() external {
    uint256 aliceShares = _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.fundReserve(100 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));

    (uint256 writtenOff, uint256 reserveUsed) = _vault.writeOff(debtShares);

    assertEq(writtenOff, 200 * _UNIT);
    assertEq(reserveUsed, 100 * _UNIT);
    assertEq(_vault.realizedBadDebt(), 200 * _UNIT);
    assertEq(_vault.totalAssets(), 900 * _UNIT);
    assertEq(_vault.convertToAssets(aliceShares), 900 * _UNIT);
    assertEq(_vault.protocolReserve(), 0);
  }

  /// @notice Removes a failed receivable once without subtracting cumulative loss again.
  function test_badDebtMetricIsNotSubtractedTwice() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));
    _vault.writeOff(debtShares);

    assertEq(_vault.totalAssets(), 800 * _UNIT);
    assertEq(_vault.realizedBadDebt(), 200 * _UNIT);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.InsufficientDebtShares.selector, 0, debtShares)
    );
    _vault.writeOff(debtShares);
    assertEq(_vault.totalAssets(), 800 * _UNIT);
    assertEq(_vault.realizedBadDebt(), 200 * _UNIT);
  }

  /// @notice Counts later incoming assets as recovery without resurrecting a receivable.
  function test_recoveryIsNewCashNotDebtResurrection() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));
    _vault.writeOff(debtShares);

    _vault.recordRecovery(50 * _UNIT);
    assertEq(_vault.internalCash(), 850 * _UNIT);
    assertEq(_vault.recoveredBadDebt(), 50 * _UNIT);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_vault.totalDebtShares(), 0);
    assertEq(_vault.totalAssets(), 850 * _UNIT);
  }

  /// @notice Applies terminal collateral before removing only the unrecovered receivable.
  function test_terminalSettlementWritesOffOnlyActualShortfall() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));

    (uint256 repaid, uint256 writtenOff, uint256 reserveUsed) =
      _vault.settleDebt(debtShares, 50 * _UNIT);

    assertEq(repaid, 50 * _UNIT);
    assertEq(writtenOff, 150 * _UNIT);
    assertEq(reserveUsed, 0);
    assertEq(_vault.internalCash(), 850 * _UNIT);
    assertEq(_vault.performingDebt(), 0);
    assertEq(_vault.totalDebtShares(), 0);
    assertEq(_vault.realizedBadDebt(), 150 * _UNIT);
    assertEq(_vault.totalAssets(), 850 * _UNIT);
  }

  /// @notice Pulls no more terminal collateral than the exact marginal receivable.
  function test_terminalSettlementLeavesExcessRecoveryWithController() external {
    _depositAs(_ALICE, 1_000 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));
    uint256 controllerBalanceBefore = _asset.balanceOf(address(this));

    (uint256 repaid, uint256 writtenOff, uint256 reserveUsed) =
      _vault.settleDebt(debtShares, 300 * _UNIT);

    assertEq(repaid, 200 * _UNIT);
    assertEq(writtenOff, 0);
    assertEq(reserveUsed, 0);
    assertEq(_asset.balanceOf(address(this)), controllerBalanceBefore - 200 * _UNIT);
    assertEq(_vault.totalAssets(), 1_000 * _UNIT);
  }

  /// @notice Burns junior reserve shares only against the post-recovery shortfall.
  function test_terminalSettlementConsumesReserveAfterRecovery() external {
    uint256 aliceShares = _depositAs(_ALICE, 1_000 * _UNIT);
    _vault.fundReserve(100 * _UNIT);
    uint256 debtShares = _vault.borrow(200 * _UNIT, address(this));

    (uint256 repaid, uint256 writtenOff, uint256 reserveUsed) =
      _vault.settleDebt(debtShares, 50 * _UNIT);

    assertEq(repaid, 50 * _UNIT);
    assertEq(writtenOff, 150 * _UNIT);
    assertEq(reserveUsed, 100 * _UNIT);
    assertEq(_vault.protocolReserve(), 0);
    assertEq(_vault.realizedBadDebt(), 150 * _UNIT);
    assertEq(_vault.convertToAssets(aliceShares), 950 * _UNIT);
    assertEq(_vault.totalAssets(), 950 * _UNIT);
  }

  // -------------------------------------------------------------------------
  // Hostile collateral and fuzz properties
  // -------------------------------------------------------------------------

  /// @notice Rejects a fee charged while collateral enters the vault.
  function test_feeOnTransferDepositRevertsWithoutAccountingChange() external {
    MockFeeOnTransferERC20 feeAsset = new MockFeeOnTransferERC20();
    DreamMarginVault feeVault =
      new DreamMarginVault(address(feeAsset), address(this), _TEST_ANNUAL_RATE_WAD);
    feeAsset.mint(_ALICE, 100 * _UNIT);
    feeAsset.setFeeBps(100);
    vm.prank(_ALICE);
    feeAsset.approve(address(feeVault), type(uint256).max);

    vm.prank(_ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.BalanceDeltaMismatch.selector,
        address(feeAsset),
        100 * _UNIT,
        99 * _UNIT
      )
    );
    feeVault.deposit(100 * _UNIT, _ALICE);
    assertEq(feeVault.totalAssets(), 0);
    assertEq(feeVault.totalSupply(), 0);
  }

  /// @notice Rejects a fee charged while assets leave and rolls back the share burn.
  function test_feeOnTransferWithdrawalRevertsAtomically() external {
    MockFeeOnTransferERC20 feeAsset = new MockFeeOnTransferERC20();
    DreamMarginVault feeVault =
      new DreamMarginVault(address(feeAsset), address(this), _TEST_ANNUAL_RATE_WAD);
    feeAsset.mint(_ALICE, 100 * _UNIT);
    vm.prank(_ALICE);
    feeAsset.approve(address(feeVault), type(uint256).max);
    vm.prank(_ALICE);
    uint256 shares = feeVault.deposit(100 * _UNIT, _ALICE);
    feeAsset.setFeeBps(100);

    vm.prank(_ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.BalanceDeltaMismatch.selector,
        address(feeAsset),
        100 * _UNIT,
        99 * _UNIT
      )
    );
    feeVault.redeem(shares, _ALICE, _ALICE);
    assertEq(feeVault.balanceOf(_ALICE), shares);
    assertEq(feeVault.totalAssets(), 100 * _UNIT);
  }

  /// @notice Blocks callback-enabled collateral from entering a second asset-moving transition.
  function test_callbackTokenCannotReenterDeposit() external {
    MockCallbackERC20 callbackAsset = new MockCallbackERC20();
    DreamMarginVault callbackVault =
      new DreamMarginVault(address(callbackAsset), address(this), _TEST_ANNUAL_RATE_WAD);
    callbackAsset.mint(_ALICE, 100 * _UNIT);
    vm.prank(_ALICE);
    callbackAsset.approve(address(callbackVault), type(uint256).max);
    callbackAsset.configureCallback(
      address(callbackVault),
      abi.encodeWithSelector(callbackVault.deposit.selector, 1, address(callbackAsset))
    );

    vm.prank(_ALICE);
    callbackVault.deposit(100 * _UNIT, _ALICE);
    assertFalse(callbackAsset.lastCallbackSucceeded());
    assertEq(
      bytes4(callbackAsset.lastCallbackReturnData()), ReentrancyGuardTransient.Reentrancy.selector
    );
    assertEq(callbackVault.totalAssets(), 100 * _UNIT);
  }

  /// @notice Supports eighteen-decimal collateral without narrowing share precision.
  function test_eighteenDecimalCollateralUsesTwentyFourShareDecimals() external {
    MockERC20 wideAsset = new MockERC20("Wide USD", "wUSD", 18);
    DreamMarginVault wideVault = new DreamMarginVault(address(wideAsset), address(this), 0);
    wideAsset.mint(_ALICE, 1e18);
    vm.prank(_ALICE);
    wideAsset.approve(address(wideVault), type(uint256).max);
    vm.prank(_ALICE);
    uint256 shares = wideVault.deposit(1e18, _ALICE);

    assertEq(wideVault.decimals(), 24);
    assertEq(shares, 1e24);
    assertEq(wideVault.convertToAssets(shares), 1e18);
  }

  /// @notice Never lets an immediate deposit-redeem round trip create assets.
  /// @param assetsSeed Fuzzed deposit amount.
  function testFuzz_depositRedeemCannotProfit(uint256 assetsSeed) external {
    uint256 assets = bound(assetsSeed, 1, 1e24);
    _asset.mint(_ALICE, assets);
    uint256 balanceBefore = _asset.balanceOf(_ALICE);
    vm.startPrank(_ALICE);
    uint256 shares = _vault.deposit(assets, _ALICE);
    uint256 redeemed = _vault.redeem(shares, _ALICE, _ALICE);
    vm.stopPrank();

    assertLe(redeemed, assets);
    assertLe(_asset.balanceOf(_ALICE), balanceBefore);
  }

  /// @notice Keeps arbitrary direct donations outside internal cash and total assets.
  /// @param donationSeed Fuzzed donation amount.
  function testFuzz_directDonationNeverChangesReportedAssets(uint256 donationSeed) external {
    uint256 donation = bound(donationSeed, 1, 1e24);
    _asset.mint(_BOB, donation);
    _depositAs(_ALICE, 10 * _UNIT);
    uint256 assetsBefore = _vault.totalAssets();
    vm.prank(_BOB);
    _asset.transfer(address(_vault), donation);

    assertEq(_vault.totalAssets(), assetsBefore);
    assertEq(_vault.unaccountedSurplus(), donation);
  }

  /// @notice Deposits assets for one configured LP.
  /// @param account Account supplying and receiving value.
  /// @param assets Assets deposited.
  /// @return shares Shares minted.
  function _depositAs(address account, uint256 assets) private returns (uint256 shares) {
    vm.prank(account);
    shares = _vault.deposit(assets, account);
  }
}

// forge-lint: disable-end(arbitrary-send-erc20, erc20-unchecked-transfer, unsafe-typecast, unused-return)
