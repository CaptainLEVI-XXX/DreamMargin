// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin transient reentrancy guard
/// @author DreamMargin contributors
/// @notice Applies one Solady EIP-1153 lock to each protected contract context.
/// @dev Shannon chain ID 50312 accepts TLOAD and TSTORE; deployment rehearsal re-proves support.

import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

/// @notice Forces Solady's transient guard path on the pinned Somnia deployment target.
abstract contract DreamMarginReentrancyGuard is ReentrancyGuardTransient {
  /// @notice Uses transient storage on every configured chain, including Somnia Shannon.
  /// @return mainnetOnly False because deployment gates prove target-chain EIP-1153 support.
  function _useTransientReentrancyGuardOnlyOnMainnet()
    internal
    pure
    virtual
    override
    returns (bool mainnetOnly)
  {
    mainnetOnly = false;
  }
}
