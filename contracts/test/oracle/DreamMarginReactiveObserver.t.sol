// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin reactive observer tests
/// @author DreamMargin contributors
/// @notice Verifies privileged routing and per-generation observation throttling.
/// @dev A selector-compatible oracle stub isolates the handler's callback policy.

import {DreamMarginReactiveObserver} from "src/oracle/DreamMarginReactiveObserver.sol";

import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Minimal stateful mark-oracle stub used by the reactive handler tests.
contract ReactiveOracleStub {
  /// @notice Number of accepted samples for each generation.
  mapping(bytes32 generationKey => uint256 count) public observations;

  /// @notice Latest accepted sample timestamp for each generation.
  mapping(bytes32 generationKey => uint40 timestamp) public newestTimestamp;

  /// @notice Returns a thirty-second observation interval and current ring metadata.
  /// @param generationKey Exact generation queried.
  /// @return config Minimal enabled oracle policy.
  /// @return ring Ring metadata derived from the stub's accepted observations.
  function generationState(bytes32 generationKey)
    external
    view
    returns (OracleConfig memory config, ObservationRing memory ring)
  {
    config.updateInterval = 30;
    config.enabled = true;
    uint256 count = observations[generationKey];
    ring.cardinality = count == 0 ? 0 : 1;
    ring.newestTimestamp = newestTimestamp[generationKey];
  }

  /// @notice Records the current timestamp as one accepted observation.
  /// @param generationKey Exact generation sampled.
  /// @return observation Minimal observation carrying the accepted timestamp.
  function observe(bytes32 generationKey) external returns (MarkObservation memory observation) {
    ++observations[generationKey];
    // Foundry test timestamps remain far below the uint40 protocol horizon.
    // forge-lint: disable-next-line(unsafe-typecast)
    newestTimestamp[generationKey] = uint40(block.timestamp);
    // Foundry test timestamps remain far below the uint40 protocol horizon.
    // forge-lint: disable-next-line(unsafe-typecast)
    observation.timestamp = uint40(block.timestamp);
  }

  /// @notice Records only when the stub's thirty-second interval has elapsed.
  /// @param generationKey Exact generation sampled.
  /// @return recorded True when this call persisted a new sample.
  function observeIfDue(bytes32 generationKey) external returns (bool recorded) {
    uint40 newest = newestTimestamp[generationKey];
    // Test-only stub mirrors the production oracle's timestamp throttle.
    // forge-lint: disable-next-line(block-timestamp)
    if (newest != 0 && block.timestamp < uint256(newest) + 30) return false;
    ++observations[generationKey];
    // Foundry test timestamps remain far below the uint40 protocol horizon.
    // forge-lint: disable-next-line(unsafe-typecast)
    newestTimestamp[generationKey] = uint40(block.timestamp);
    recorded = true;
  }
}

/// @notice Exercises the two-pool callback boundary with few focused cases.
contract DreamMarginReactiveObserverTest is Test {
  address private constant _PRECOMPILE = address(0x0100);
  address private constant _BTC_POOL = address(0xB7C);
  address private constant _ETH_POOL = address(0xE7A);
  bytes32 private constant _BTC_YES = keccak256("BTC_YES");
  bytes32 private constant _BTC_NO = keccak256("BTC_NO");
  bytes32 private constant _ETH_YES = keccak256("ETH_YES");
  bytes32 private constant _ETH_NO = keccak256("ETH_NO");

  ReactiveOracleStub private _oracle;
  DreamMarginReactiveObserver private _observer;

  /// @notice Deploys a fresh oracle stub and immutable callback handler.
  function setUp() external {
    _oracle = new ReactiveOracleStub();
    _observer = new DreamMarginReactiveObserver(
      address(_oracle), _BTC_POOL, _BTC_YES, _BTC_NO, _ETH_POOL, _ETH_YES, _ETH_NO
    );
  }

  /// @notice Rejects direct callers before any oracle state can change.
  function test_rejectsCallerOutsideReactivityPrecompile() external {
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.NotReactivityPrecompile.selector, address(this), _PRECOMPILE
      )
    );
    _observer.onEvent(_BTC_POOL, new bytes32[](0), "");
  }

  /// @notice Routes a pool callback only to that market's two exact outcomes.
  function test_routesCallbackToMatchingMarketOutcomes() external {
    vm.prank(_PRECOMPILE);
    _observer.onEvent(_BTC_POOL, new bytes32[](0), "");

    assertEq(_oracle.observations(_BTC_YES), 1);
    assertEq(_oracle.observations(_BTC_NO), 1);
    assertEq(_oracle.observations(_ETH_YES), 0);
    assertEq(_oracle.observations(_ETH_NO), 0);
  }

  /// @notice Coalesces repeated callbacks until each generation's interval elapses.
  function test_observesAgainOnlyAfterUpdateInterval() external {
    vm.startPrank(_PRECOMPILE);
    _observer.onEvent(_ETH_POOL, new bytes32[](0), "");
    _observer.onEvent(_ETH_POOL, new bytes32[](0), "");
    vm.warp(block.timestamp + 30);
    _observer.onEvent(_ETH_POOL, new bytes32[](0), "");
    vm.stopPrank();

    assertEq(_oracle.observations(_ETH_YES), 2);
    assertEq(_oracle.observations(_ETH_NO), 2);
  }
}
