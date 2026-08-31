// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX local integration model tests
/// @author DreamMargin contributors
/// @notice Verifies authorization, immediate execution, empty books, and recycling.
/// @dev These tests assert value movement and generation behavior rather than
///      restating interface selectors.

import {Test} from "forge-std/Test.sol";

import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {
  MockDreamDexBinaryPool,
  MockDreamDexInvalidOrderType
} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909, MockERC6909Unauthorized} from "test/mock/MockERC6909.sol";

/// @notice Exercises the local DreamDEX token and pool models.
contract DreamDexModelTest is Test {
  /// @notice YES outcome ID used by the first mock generation.
  uint256 private constant _YES_ID = 101;

  /// @notice NO outcome ID used by the first mock generation.
  uint256 private constant _NO_ID = 102;

  /// @notice One collateral unit for the six-decimal mock token.
  uint256 private constant _ONE = 1e6;

  /// @notice Initial trader collateral balance.
  uint256 private constant _TRADER_COLLATERAL = 10 * _ONE;

  /// @notice Initial pool inventory per asset.
  uint256 private constant _POOL_LIQUIDITY = 100 * _ONE;

  /// @notice YES-side test price.
  uint256 private constant _YES_PRICE = 600_000;

  /// @notice Quantity used by immediate-order tests.
  uint256 private constant _ORDER_QUANTITY = 4 * _ONE;

  /// @notice Half-fill ratio in basis points.
  uint256 private constant _HALF_FILL_BPS = 5_000;

  /// @notice Fixed test block timestamp in seconds.
  uint256 private constant _TIMESTAMP = 1_000_000;

  /// @notice Fixed order deadline in nanoseconds.
  uint64 private constant _ORDER_DEADLINE_NS = 1_003_600 * 1e9;

  /// @notice Fixed initial pool expiry in nanoseconds.
  uint64 private constant _POOL_EXPIRY_NS = 1_086_400 * 1e9;

  /// @notice Fixed recycled pool expiry in nanoseconds.
  uint64 private constant _NEXT_POOL_EXPIRY_NS = 1_172_800 * 1e9;

  /// @notice Opaque order data used to verify argument forwarding.
  uint64 private constant _USER_DATA = 7;

  /// @notice Recycled market address.
  address private constant _NEXT_MARKET = address(0xD00D);

  /// @notice Recycled YES outcome ID.
  uint256 private constant _NEXT_YES_ID = 201;

  /// @notice Recycled NO outcome ID.
  uint256 private constant _NEXT_NO_ID = 202;

  /// @notice Test trader address.
  address private constant _TRADER = address(0xBEEF);

  /// @notice Mock collateral token.
  MockERC20 private _collateral;

  /// @notice Mock outcome-token singleton.
  MockERC6909 private _outcome;

  /// @notice Mock binary pool.
  MockDreamDexBinaryPool private _pool;

  /// @notice Creates a liquid binary-pool fixture.
  function setUp() external {
    vm.warp(_TIMESTAMP);
    _collateral = new MockERC20("Test USD", "tUSD", 6);
    _outcome = new MockERC6909();

    IDreamDexBinaryPool.BinaryPoolInfo memory info = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(_collateral),
      market: address(0xCAFE),
      outcomeToken: address(_outcome),
      yesId: _YES_ID,
      noId: _NO_ID,
      oneCollateral: _ONE,
      setBacking: _ONE,
      feeRecipient: address(0xFEE),
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: address(0x5151),
      marketNonce: 1,
      finalized: false
    });
    IDreamDexBinaryPool.OrderBookParameters memory parameters =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(info, parameters, _POOL_EXPIRY_NS);

    _collateral.mint(_TRADER, _TRADER_COLLATERAL);
    _collateral.mint(address(_pool), _POOL_LIQUIDITY);
    _outcome.mint(address(_pool), _YES_ID, _POOL_LIQUIDITY);
    _outcome.mint(address(_pool), _NO_ID, _POOL_LIQUIDITY);
  }

  /// @notice Proves an exact-ID allowance cannot move another outcome ID.
  function test_exactIdAllowanceCannotSpendAnotherOutcome() external {
    _outcome.mint(_TRADER, _YES_ID, 2 * _ONE);
    _outcome.mint(_TRADER, _NO_ID, 2 * _ONE);

    vm.prank(_TRADER);
    assertTrue(_outcome.approve(address(this), _YES_ID, _ONE));

    vm.expectRevert(
      abi.encodeWithSelector(MockERC6909Unauthorized.selector, _TRADER, address(this), _NO_ID)
    );
    // The call is expected to revert before returning a Boolean.
    // forge-lint: disable-next-line(unused-return)
    _outcome.transferFrom(_TRADER, address(this), _NO_ID, _ONE);

    assertTrue(_outcome.transferFrom(_TRADER, address(this), _YES_ID, _ONE));
    assertEq(_outcome.balanceOf(address(this), _YES_ID), _ONE);
    assertEq(_outcome.allowance(_TRADER, address(this), _YES_ID), 0);
  }

  /// @notice Proves a global operator can move multiple IDs from protocol custody.
  function test_operatorCanSpendMultipleOutcomeIds() external {
    _outcome.mint(_TRADER, _YES_ID, _ONE);
    _outcome.mint(_TRADER, _NO_ID, _ONE);

    vm.prank(_TRADER);
    assertTrue(_outcome.setOperator(address(this), true));

    assertTrue(_outcome.transferFrom(_TRADER, address(this), _YES_ID, _ONE));
    assertTrue(_outcome.transferFrom(_TRADER, address(this), _NO_ID, _ONE));
    assertEq(_outcome.balanceOf(address(this), _YES_ID), _ONE);
    assertEq(_outcome.balanceOf(address(this), _NO_ID), _ONE);
  }

  /// @notice Verifies an IOC buy reconciles the configured partial fill by balances.
  function test_iocBuyMovesOnlyActuallyFilledBalances() external {
    _pool.setExecution(_HALF_FILL_BPS, 0);
    vm.startPrank(_TRADER);
    assertTrue(_collateral.approve(address(_pool), type(uint256).max));

    (bool success, uint128 orderId) = _pool.placeBinaryOrder(
      0, _YES_PRICE, _ORDER_QUANTITY, _ORDER_DEADLINE_NS, 2, 0, address(0), 0, _USER_DATA
    );
    vm.stopPrank();

    assertTrue(success);
    assertEq(orderId, 0);
    assertEq(_outcome.balanceOf(_TRADER, _YES_ID), 2 * _ONE);
    assertEq(_collateral.balanceOf(_TRADER), _TRADER_COLLATERAL - 1_200_000);
    assertEq(_pool.lastUserData(), _USER_DATA);
  }

  /// @notice Verifies FOK rejects a partial fill without moving any value.
  function test_fokRejectsPartialFillAtomically() external {
    _pool.setExecution(_HALF_FILL_BPS, 0);
    vm.startPrank(_TRADER);
    assertTrue(_collateral.approve(address(_pool), type(uint256).max));

    (bool success, uint128 orderId) = _pool.placeBinaryOrder(
      0, _YES_PRICE, _ORDER_QUANTITY, _ORDER_DEADLINE_NS, 1, 0, address(0), 0, 0
    );
    vm.stopPrank();

    assertFalse(success);
    assertEq(orderId, 0);
    assertEq(_outcome.balanceOf(_TRADER, _YES_ID), 0);
    assertEq(_collateral.balanceOf(_TRADER), _TRADER_COLLATERAL);
  }

  /// @notice Verifies resting order types are rejected by the binary model.
  function test_rejectsNonImmediateOrderType() external {
    vm.expectRevert(abi.encodeWithSelector(MockDreamDexInvalidOrderType.selector, 0));
    vm.prank(_TRADER);
    // The call is expected to revert before returning its result tuple.
    // forge-lint: disable-next-line(unused-return)
    _pool.placeBinaryOrder(0, _YES_PRICE, _ONE, _ORDER_DEADLINE_NS, 0, 0, address(0), 0, 0);
  }

  /// @notice Verifies an empty on-chain book is represented by an empty array.
  function test_emptyBookReturnsEmptyArray() external view {
    IDreamDexBinaryPool.BookLevel[] memory levels = _pool.getBookLevels(true, 8);
    assertEq(levels.length, 0);
  }

  /// @notice Verifies recycling changes the full generation binding.
  function test_recycleChangesNonceAndOutcomeIds() external {
    IDreamDexBinaryPool.BinaryPoolInfo memory next = _pool.getBinaryPoolParams();
    next.market = _NEXT_MARKET;
    next.yesId = _NEXT_YES_ID;
    next.noId = _NEXT_NO_ID;
    next.marketNonce = 2;

    _pool.recycle(next, _NEXT_POOL_EXPIRY_NS);
    IDreamDexBinaryPool.BinaryPoolInfo memory actual = _pool.getBinaryPoolParams();

    assertEq(actual.market, _NEXT_MARKET);
    assertEq(actual.marketNonce, 2);
    assertEq(actual.yesId, _NEXT_YES_ID);
    assertEq(actual.noId, _NEXT_NO_ID);
  }
}
