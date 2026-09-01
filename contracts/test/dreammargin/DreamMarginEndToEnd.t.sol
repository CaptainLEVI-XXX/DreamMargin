// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin end-to-end smoke test
/// @author DreamMargin contributors
/// @notice Exercises one compact path across liquidity, margin, exit, liquidation, and settlement.
/// @dev The whole-system handler supplies deterministic actors and complete integration models.

import {
  Position,
  PositionStatus,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

import {DreamMarginSystemHandler} from "test/invariant/handler/DreamMarginSystemHandler.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Verifies that the assembled product completes its principal user lifecycles.
contract DreamMarginEndToEndTest is Test {
  /// @notice Runs seeded critical paths, an ordinary trader exit, and an available LP redemption.
  function test_completeProductLifecycle() external {
    DreamMarginSystemHandler handler = new DreamMarginSystemHandler();
    handler.initialize();

    assertEq(handler.successfulOpens(), 3);
    assertEq(handler.successfulLiquidations(), 1);
    assertEq(handler.successfulSettlements(), 1);
    assertEq(handler.pauseSafetyProofs(), 1);
    assertEq(handler.unauthorizedRejections(), 1);
    assertEq(uint8(handler.controller().protocolMode()), uint8(ProtocolMode.ACTIVE));

    handler.actOpen(0);
    uint256 positionId = handler.positionIds(handler.positionCount() - 1);
    handler.actExit(3);
    Position memory exited = handler.controller().getPosition(positionId);
    assertEq(uint8(exited.status), uint8(PositionStatus.CLOSED));
    assertEq(exited.shares, 0);
    assertEq(exited.debtShares, 0);

    uint256 redeemable = handler.vault().maxRedeem(address(handler));
    assertGt(redeemable, 0);
    uint256 supplyBefore = handler.vault().totalSupply();
    uint256 assetsBefore = handler.collateral().balanceOf(address(handler));
    handler.actVault(999_999);
    assertLt(handler.vault().totalSupply(), supplyBefore);
    assertGt(handler.collateral().balanceOf(address(handler)), assetsBefore);

    assertFalse(handler.riskIncreaseViolation());
    assertFalse(handler.liquidationEligibilityViolation());
    assertFalse(handler.generationBindingViolation());
    assertFalse(handler.authorizationViolation());
    assertFalse(handler.pauseSafetyViolation());
    assertFalse(handler.debtFirstViolation());
    assertFalse(handler.executionBoundsViolation());
    assertFalse(handler.roundingViolation());
  }
}
