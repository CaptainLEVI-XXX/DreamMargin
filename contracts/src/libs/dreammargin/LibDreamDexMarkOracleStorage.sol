// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// @title DreamDEX mark-oracle storage
// @author DreamMargin contributors
// @notice Defines generation configuration and bounded on-chain observation rings.
// @dev Observations preserve raw collateral units and the exact pool nonce sampled.

import {MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

/// @notice One time-weighted, size-aware DreamDEX generation observation.
/// @param timestamp Observation timestamp in seconds.
/// @param poolNonce Pool generation nonce read during the sample.
/// @param marketStatus Authoritative DreamDEX market status sampled on-chain.
/// @param bestBid Same-outcome best bid in collateral native units per whole outcome.
/// @param sameSideDepthBid Size-aware same-outcome bid in collateral native units.
/// @param oppositeSideDepthAsk Size-aware opposite-outcome ask in collateral native units.
/// @param conservativeMark Minimum manipulation-resistant mark admitted for accumulation.
/// @param cumulativeMarkSeconds Cumulative conservative mark multiplied by elapsed seconds.
struct MarkObservation {
  uint40 timestamp;
  uint64 poolNonce;
  uint8 marketStatus;
  uint128 bestBid;
  uint128 sameSideDepthBid;
  uint128 oppositeSideDepthAsk;
  uint128 conservativeMark;
  uint256 cumulativeMarkSeconds;
}

/// @notice Bounded observation policy for one exact market generation.
/// @param key Full tuple whose hash indexes observations.
/// @param minAge Minimum mature-window age in seconds.
/// @param updateInterval Minimum seconds between accepted observations.
/// @param staleAfter Maximum age of the newest observation in seconds.
/// @param depthQuantity Outcome quantity walked when producing depth-aware marks.
/// @param maxObservations Capacity of the circular observation ring.
/// @param maxBookLevels Maximum levels walked from either side of the book.
/// @param enabled Whether permissionless updates are accepted for the generation.
struct OracleConfig {
  MarketKey key;
  uint40 minAge;
  uint40 updateInterval;
  uint40 staleAfter;
  uint128 depthQuantity;
  uint16 maxObservations;
  uint16 maxBookLevels;
  bool enabled;
}

/// @notice Metadata for one bounded circular observation ring.
/// @param nextIndex Ring index overwritten by the next accepted observation.
/// @param cardinality Number of initialized entries, capped by configuration.
/// @param oldestTimestamp Timestamp of the oldest retained observation.
/// @param newestTimestamp Timestamp of the newest retained observation.
struct ObservationRing {
  uint16 nextIndex;
  uint16 cardinality;
  uint40 oldestTimestamp;
  uint40 newestTimestamp;
}

// ERC-7201 slot for `dreammargin.storage.MarkOracle`.
// Derivation: `keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff))`.
// Value: `0xb852e7e1a1b2d1faf404d44e6e08356d238ab84c37e1bdda87c61b889917fb00`.
bytes32 constant DREAM_DEX_MARK_ORACLE_STORAGE_SLOT =
  0xb852e7e1a1b2d1faf404d44e6e08356d238ab84c37e1bdda87c61b889917fb00;

/// @title DreamDEX mark-oracle storage accessor
/// @author DreamMargin contributors
/// @notice Accesses and mutates DreamDEX mark-oracle state.
/// @dev Observations preserve raw collateral units and the exact pool nonce sampled.
library LibDreamDexMarkOracleStorage {
  /// @notice Complete mutable state of the DreamDEX mark oracle.
  /// @param configs Observation policy by full generation key.
  /// @param rings Circular-ring metadata by full generation key.
  /// @param observations Ring entries by generation key and bounded index.
  /// @param initialized Whether oracle initialization has completed.
  struct State {
    mapping(bytes32 generationKey => OracleConfig config) configs;
    mapping(bytes32 generationKey => ObservationRing ring) rings;
    mapping(bytes32 generationKey => mapping(uint16 index => MarkObservation observation))
      observations;
    bool initialized;
  }

  /// @notice Returns the mark-oracle state stored at its ERC-7201 namespace.
  /// @dev Memory layout: `slot` is one stack word containing the namespace root.
  ///      1. Bind the returned storage pointer to that root.
  ///      Safety Considerations: THE LITERAL SLOT DERIVATION IS VERIFIED BY TEST;
  ///      THIS ACCESSOR DOES NOT VALIDATE FIELD LAYOUT OR UPGRADE COMPATIBILITY.
  /// @return self Storage reference to the oracle state.
  function get() internal pure returns (State storage self) {
    bytes32 slot = DREAM_DEX_MARK_ORACLE_STORAGE_SLOT;
    assembly ("memory-safe") {
      self.slot := slot
    }
  }
}
