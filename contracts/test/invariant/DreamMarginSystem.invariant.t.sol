// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin whole-system invariants
/// @author DreamMargin contributors
/// @notice Checks the protocol's named safety properties after compact stateful sequences.
/// @dev One handler supplies successful lifecycle coverage; assertions remain state-based.

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {
  GenerationConfig,
  Position,
  PositionStatus,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibPositionRisk} from "src/libs/dreammargin/LibPositionRisk.sol";
import {DreamMarginSystemHandler} from "test/invariant/handler/DreamMarginSystemHandler.sol";

// Bounded registry enumeration is deliberate in invariant assertions.
// forge-lint: disable-start(calls-loop, uninitialized-local)

/// @notice Executes the whole-system handler and asserts DM-I1 through DM-I15.
contract DreamMarginSystemInvariantTest is StdInvariant, Test {
  DreamMarginSystemHandler private _handler;

  function setUp() external {
    _handler = new DreamMarginSystemHandler();
    _handler.initialize();
    targetContract(address(_handler));
  }

  /// @notice DM-I1: live position debt equals every controller and vault debt bucket.
  function invariant_I1_debtReconciliation() external view {
    uint256 total;
    uint256 active;
    uint256 terminal;
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      Position memory position = _handler.controller().getPosition(_handler.positionIds(i));
      if (position.status != PositionStatus.ACTIVE) continue;
      total += position.debtShares;
      if (position.pool == address(_handler.activePool())) active += position.debtShares;
      else terminal += position.debtShares;
    }
    assertEq(total, _handler.vault().totalDebtShares());
    assertEq(
      total,
      _totalBucket(
        _handler.activeGenerationKey(), _handler.activeMarketGroup(), _handler.activeOutcomeId()
      )
    );
    assertEq(
      active,
      _bucket(
        _handler.activeGenerationKey(), _handler.activeMarketGroup(), _handler.activeOutcomeId()
      )
    );
    assertEq(
      terminal,
      _bucket(
        _handler.terminalGenerationKey(),
        _handler.terminalMarketGroup(),
        _handler.terminalOutcomeId()
      )
    );
  }

  /// @notice DM-I2: exact-ID custody covers every live attributed share.
  function invariant_I2_exactCustody() external view {
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      Position memory position = _handler.controller().getPosition(_handler.positionIds(i));
      uint256 expected = _sharesFor(position.outcomeToken, position.outcomeId);
      (uint256 attributed,,,) = _handler.controller()
        .aggregateState(
          _generation(position), _marketGroup(position), position.outcomeToken, position.outcomeId
        );
      assertEq(attributed, expected);
      assertEq(
        _handler.outcome().balanceOf(address(_handler.controller()), position.outcomeId), expected
      );
    }
  }

  /// @notice DM-I3: every live debt-bearing position retains outcome collateral.
  function invariant_I3_debtHasCollateral() external view {
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      Position memory position = _handler.controller().getPosition(_handler.positionIds(i));
      if (position.status == PositionStatus.ACTIVE && position.debtShares != 0) {
        assertGt(position.shares, 0);
        assertGe(
          _handler.outcome().balanceOf(address(_handler.controller()), position.outcomeId),
          position.shares
        );
      }
    }
  }

  /// @notice DM-I4: reduction actions never return owner surplus while leaving debt unchanged.
  function invariant_I4_debtFirst() external view {
    assertFalse(_handler.debtFirstViolation());
  }

  /// @notice DM-I5: the complete generation tuple remains pinned for every position.
  function invariant_I5_generationBinding() external view {
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      uint256 id = _handler.positionIds(i);
      Position memory position = _handler.controller().getPosition(id);
      assertEq(_identity(position), _handler.positionIdentity(id));
    }
    assertFalse(_handler.generationBindingViolation());
  }

  /// @notice DM-I6: every successful risk increase stayed inside independent risk bounds.
  function invariant_I6_riskIncreaseBounds() external view {
    assertFalse(_handler.riskIncreaseViolation());
    assertGt(_handler.successfulOpens(), 0);
  }

  /// @notice DM-I7: ordinary liquidation succeeded only after an independent eligibility check.
  function invariant_I7_liquidationEligibility() external view {
    assertFalse(_handler.liquidationEligibilityViolation());
    assertGt(_handler.successfulLiquidations(), 0);
  }

  /// @notice DM-I8: expiry compression tightens maintenance monotonically as expiry approaches.
  function invariant_I8_expiryMonotonicity() external pure {
    uint256 near = LibPositionRisk.maintenanceLtvBps(7_500, 1_000, 3_600);
    uint256 far = LibPositionRisk.maintenanceLtvBps(7_500, 10_000, 3_600);
    assertLe(near, far);
  }

  /// @notice DM-I9: debt conversion and stored accounting round in favor of the vault.
  function invariant_I9_conservativeRounding() external view {
    uint256 shares = _handler.vault().totalDebtShares();
    assertGe(
      _handler.vault().debtAssets(shares),
      _handler.vault().performingDebt() + _handler.vault().collectibleInterest()
    );
    assertFalse(_handler.roundingViolation());
  }

  /// @notice DM-I10: vault reported assets reconcile to cash, principal, and stored interest.
  function invariant_I10_vaultAccounting() external view {
    uint256 stored = _handler.vault().internalCash() + _handler.vault().performingDebt()
      + _handler.vault().collectibleInterest();
    uint256 reported = _handler.vault().totalAssets();
    assertGe(reported, stored);
    assertLe(reported - stored, _handler.vault().totalDebtShares() + 1);
    assertGe(
      _handler.collateral().balanceOf(address(_handler.vault())), _handler.vault().internalCash()
    );
  }

  /// @notice DM-I11: recoveries are final and cannot recreate a receivable.
  function invariant_I11_lossFinality() external view {
    assertLe(_handler.vault().recoveredBadDebt(), _handler.vault().realizedBadDebt());
    if (_handler.vault().totalDebtShares() == 0) {
      assertEq(_handler.vault().performingDebt(), 0);
      assertEq(_handler.vault().collectibleInterest(), 0);
    }
  }

  /// @notice DM-I12: accepted venue writes obey the immediate-order execution envelope.
  function invariant_I12_executionBounds() external view {
    assertFalse(_handler.executionBoundsViolation());
  }

  /// @notice DM-I13: exact approvals and temporary settlement operators remain bounded.
  function invariant_I13_approvalScope() external view {
    assertFalse(_handler.authorizationViolation());
    assertFalse(
      _handler.outcome().isOperator(address(_handler.controller()), address(_handler.settlement()))
    );
    assertGt(_handler.unauthorizedRejections(), 0);
  }

  /// @notice DM-I14: paused mode rejects risk increases while reductions remain available.
  function invariant_I14_pauseSafety() external view {
    assertFalse(_handler.pauseSafetyViolation());
    assertGt(_handler.pauseSafetyProofs(), 0);
    assertEq(uint8(_handler.controller().protocolMode()), uint8(ProtocolMode.PAUSED));
  }

  /// @notice DM-I15: closed positions stay permanently zeroed.
  function invariant_I15_closedFinality() external view {
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      Position memory position = _handler.controller().getPosition(_handler.positionIds(i));
      if (position.status == PositionStatus.CLOSED) {
        assertEq(position.shares, 0);
        assertEq(position.debtShares, 0);
      }
    }
    assertGt(_handler.successfulSettlements(), 0);
  }

  function _generation(Position memory position) private view returns (bytes32) {
    return position.pool == address(_handler.activePool())
      ? _handler.activeGenerationKey()
      : _handler.terminalGenerationKey();
  }

  function _marketGroup(Position memory position) private view returns (bytes32) {
    return position.pool == address(_handler.activePool())
      ? _handler.activeMarketGroup()
      : _handler.terminalMarketGroup();
  }

  function _sharesFor(address token, uint256 outcomeId) private view returns (uint256 shares) {
    uint256 length = _handler.positionCount();
    for (uint256 i; i < length; ++i) {
      Position memory position = _handler.controller().getPosition(_handler.positionIds(i));
      if (
        position.outcomeToken == token && position.outcomeId == outcomeId
          && position.status == PositionStatus.ACTIVE
      ) {
        shares += position.shares;
      }
    }
  }

  function _bucket(bytes32 generationKey, bytes32 marketGroup, uint256 outcomeId)
    private
    view
    returns (uint256 shares)
  {
    (,, shares,) = _handler.controller()
      .aggregateState(generationKey, marketGroup, address(_handler.outcome()), outcomeId);
  }

  function _totalBucket(bytes32 generationKey, bytes32 marketGroup, uint256 outcomeId)
    private
    view
    returns (uint256 shares)
  {
    (,,, shares) = _handler.controller()
      .aggregateState(generationKey, marketGroup, address(_handler.outcome()), outcomeId);
  }

  function _identity(Position memory position) private pure returns (bytes32 digest) {
    digest = keccak256(
      abi.encode(
        position.owner,
        position.marketId,
        position.pool,
        position.outcomeToken,
        position.outcomeId,
        position.initialEquity,
        position.marketNonce,
        position.openedAt,
        position.expiry,
        position.outcomeIndex
      )
    );
  }
}

// forge-lint: disable-end(calls-loop, uninitialized-local)
