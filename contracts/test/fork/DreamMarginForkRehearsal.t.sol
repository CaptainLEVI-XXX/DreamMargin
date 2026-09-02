// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin fork-profile deployment rehearsal test
/// @author DreamMargin contributors
/// @notice Proves deployment, configuration, and a full LP/trader smoke flow without testnet funds.
/// @dev Deployed DreamDEX reads are real and pinned. All writes execute against the explicit local
///      mirror described by `DreamMarginForkRehearsal`; this test is not live-write evidence.

import {
  DreamMarginForkRehearsal,
  ForkRehearsalResult
} from "test/fork/harness/DreamMarginForkRehearsal.sol";
import {ShannonSnapshot, ShannonSnapshotReader} from "test/fork/harness/ShannonSnapshot.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Runs the deterministic pinned-source deployment rehearsal.
contract DreamMarginForkRehearsalTest is Test {
  /// @notice Covers source proof, bindings, roles, registration, deposit, open, repay, close, and exit.
  function test_pinnedSourceFullDeploymentAndLifecycle() external {
    ShannonSnapshot memory source = ShannonSnapshotReader.read(vm);
    DreamMarginForkRehearsal rehearsal = new DreamMarginForkRehearsal();
    ForkRehearsalResult memory result = rehearsal.run(source);

    assertEq(result.sourceFingerprint, source.sourceFingerprint);
    assertEq(result.sourceModule, source.module);
    assertEq(result.sourceMarket, source.market);
    assertEq(result.sourcePool, source.pool);
    assertTrue(result.generationKey != bytes32(0));
    assertTrue(result.controller.code.length != 0);
    assertTrue(result.vault.code.length != 0);
    assertTrue(result.oracle.code.length != 0);
    assertEq(result.positionId, 1);
    assertEq(result.lpAssetsDeposited, 500 * source.oneCollateral);
    assertGe(result.lpAssetsWithdrawn, result.lpAssetsDeposited);
  }
}
