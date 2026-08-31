// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX conservative mark-oracle interface
/// @author DreamMargin contributors
/// @notice Exposes permissionless observations and mature generation-bound valuation.
/// @dev Values use collateral native units and fail closed for risk-increasing actions.

import {
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";

interface IDreamDexMarkOracle {
  /// @notice Configures one exact generation observation policy through bounded governance.
  /// @param generationKey Full market-generation key.
  /// @param config Observation policy and immutable generation tuple.
  function configureGeneration(bytes32 generationKey, OracleConfig calldata config) external;

  /// @notice Samples the current on-chain DreamDEX book for an eligible generation.
  /// @param generationKey Full market-generation key.
  /// @return observation Accepted depth-aware observation.
  function observe(bytes32 generationKey) external returns (MarkObservation memory observation);

  /// @notice Returns one retained observation from the bounded ring.
  /// @param generationKey Full market-generation key.
  /// @param index Ring index queried.
  /// @return observation Retained observation at the index.
  function observationAt(bytes32 generationKey, uint16 index)
    external
    view
    returns (MarkObservation memory observation);

  /// @notice Returns observation policy and ring metadata for one generation.
  /// @param generationKey Full market-generation key.
  /// @return config Current observation policy.
  /// @return ring Current circular-ring metadata.
  function generationState(bytes32 generationKey)
    external
    view
    returns (OracleConfig memory config, ObservationRing memory ring);

  /// @notice Returns a mature conservative TWAP for solvency checks.
  /// @param generationKey Full market-generation key.
  /// @return mark Time-weighted mark in collateral native units per whole outcome.
  /// @return age Age of the retained observation window in seconds.
  /// @return updatedAt Timestamp of the newest observation in seconds.
  function conservativeTwap(bytes32 generationKey)
    external
    view
    returns (uint256 mark, uint256 age, uint256 updatedAt);
}
