// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX generation-bound mark oracle
/// @author DreamMargin contributors
/// @notice Records permissionless depth-aware observations and exposes mature conservative TWAPs.
/// @dev Every update and risk-increasing read revalidates the exact recyclable pool generation.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {
  LibDreamDexMarkOracleStorage,
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {LibDreamMarginStorage, MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibPositionRisk} from "src/libs/dreammargin/LibPositionRisk.sol";

/// @notice Bounded on-chain oracle for exact DreamDEX market generations.
contract DreamDexMarkOracle is IDreamDexMarkOracle, DreamDexAdapter {
  /// @notice Statically bound DreamDEX binary module.
  address private immutable _MODULE;

  /// @notice Sole account permitted to register and disable observation policies.
  address private immutable _CONFIGURATOR;

  /// @notice Binds the oracle to one module and one immutable configurator.
  /// @param module_ DreamDEX binary module.
  /// @param configurator_ Account registering exact generation policies.
  constructor(address module_, address configurator_) {
    if (module_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("MODULE");
    if (configurator_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("CONFIGURATOR");
    _MODULE = module_;
    _CONFIGURATOR = configurator_;
    LibDreamDexMarkOracleStorage.get().initialized = true;
  }

  /// @notice Restricts generation policy mutation to the immutable configurator.
  modifier onlyConfigurator() {
    _checkConfigurator();
    _;
  }

  /// @inheritdoc IDreamDexMarkOracle
  function module() external view returns (address module_) {
    module_ = _MODULE;
  }

  /// @inheritdoc IDreamDexMarkOracle
  function configurator() external view returns (address configurator_) {
    configurator_ = _CONFIGURATOR;
  }

  /// @inheritdoc IDreamDexMarkOracle
  function configureGeneration(bytes32 generationKey, OracleConfig calldata config)
    external
    onlyConfigurator
  {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    if (self.configs[generationKey].key.pool != address(0)) {
      revert LibDreamMarginErrors.GenerationAlreadyConfigured(generationKey);
    }
    MarketKey memory key = config.key;
    bytes32 derivedKey = LibDreamMarginStorage.generationKey(key);
    if (derivedKey != generationKey) {
      revert LibDreamMarginErrors.GenerationMismatch(generationKey, derivedKey);
    }
    _validatePolicy(config);
    _validateCurrentGeneration(key);
    self.configs[generationKey] = config;
    emit GenerationConfigured(generationKey);
  }

  /// @inheritdoc IDreamDexMarkOracle
  function disableGeneration(bytes32 generationKey) external onlyConfigurator {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    OracleConfig storage config = self.configs[generationKey];
    if (config.key.pool == address(0)) {
      revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    }
    config.enabled = false;
    emit GenerationDisabled(generationKey);
  }

  /// @inheritdoc IDreamDexMarkOracle
  function observe(bytes32 generationKey) external returns (MarkObservation memory observation) {
    (bool recorded, MarkObservation memory sampled) = _observe(generationKey, true);
    // Strict mode either records or reverts when the interval has not elapsed.
    assert(recorded);
    observation = sampled;
  }

  /// @inheritdoc IDreamDexMarkOracle
  function observeIfDue(bytes32 generationKey) external returns (bool recorded) {
    (recorded,) = _observe(generationKey, false);
  }

  /// @notice Validates and optionally records one due observation.
  /// @param generationKey Full market-generation key.
  /// @param strict Whether an early call reverts instead of returning false.
  /// @return recorded Whether a new observation was persisted.
  /// @return observation Newly persisted observation, or zero values when skipped.
  function _observe(bytes32 generationKey, bool strict)
    private
    returns (bool recorded, MarkObservation memory observation)
  {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    OracleConfig storage config = self.configs[generationKey];
    if (!config.enabled) revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    uint8 outcomeIndex = _validateCurrentGeneration(config.key);
    _requireBeforeExpiry(config.key);

    ObservationRing storage ring = self.rings[generationKey];
    uint40 timestamp = _timestamp40();
    if (ring.cardinality != 0) {
      uint256 elapsed = timestamp - ring.newestTimestamp;
      if (elapsed < config.updateInterval) {
        if (!strict) return (recorded, observation);
        revert LibDreamMarginErrors.ObservationTooSoon(elapsed, config.updateInterval);
      }
    }

    (
      uint256 bestBid,
      uint256 sameSideDepthBid,
      uint256 oppositeSideDepthAsk,
      uint256 conservativeMark
    ) = _sampleBook(config, generationKey, outcomeIndex);

    uint256 cumulative = 0;
    if (ring.cardinality != 0) {
      MarkObservation storage previous =
        self.observations[generationKey][_latestIndex(ring, config)];
      cumulative = previous.cumulativeMarkSeconds + uint256(previous.conservativeMark)
        * (timestamp - previous.timestamp);
    }
    observation = MarkObservation({
      timestamp: timestamp,
      poolNonce: config.key.marketNonce,
      marketStatus: LibDreamMarginConstants.MARKET_STATUS_TRADING,
      bestBid: _uint128("BEST_BID", bestBid),
      sameSideDepthBid: _uint128("DEPTH_BID", sameSideDepthBid),
      oppositeSideDepthAsk: _uint128("DEPTH_ASK", oppositeSideDepthAsk),
      conservativeMark: _uint128("CONSERVATIVE_MARK", conservativeMark),
      cumulativeMarkSeconds: cumulative
    });

    uint16 writtenIndex = ring.nextIndex;
    self.observations[generationKey][writtenIndex] = observation;
    // Modulo by a validated uint16 capacity proves the result fits uint16.
    // forge-lint: disable-next-line(unsafe-typecast)
    ring.nextIndex = uint16((uint256(writtenIndex) + 1) % config.maxObservations);
    if (ring.cardinality < config.maxObservations) {
      ++ring.cardinality;
    }
    ring.newestTimestamp = timestamp;
    uint16 oldestIndex = ring.cardinality == config.maxObservations ? ring.nextIndex : 0;
    ring.oldestTimestamp = self.observations[generationKey][oldestIndex].timestamp;
    emit ObservationRecorded(generationKey, writtenIndex, timestamp, observation.conservativeMark);
    recorded = true;
  }

  /// @inheritdoc IDreamDexMarkOracle
  function observationAt(bytes32 generationKey, uint16 index)
    external
    view
    returns (MarkObservation memory observation)
  {
    OracleConfig storage config = LibDreamDexMarkOracleStorage.get().configs[generationKey];
    if (config.key.pool == address(0)) {
      revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    }
    if (index >= config.maxObservations) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "OBSERVATION_INDEX", index, config.maxObservations - 1
      );
    }
    observation = LibDreamDexMarkOracleStorage.get().observations[generationKey][index];
  }

  /// @inheritdoc IDreamDexMarkOracle
  function generationState(bytes32 generationKey)
    external
    view
    returns (OracleConfig memory config, ObservationRing memory ring)
  {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    config = self.configs[generationKey];
    ring = self.rings[generationKey];
  }

  /// @inheritdoc IDreamDexMarkOracle
  function conservativeTwap(bytes32 generationKey)
    external
    view
    returns (uint256 mark, uint256 age, uint256 updatedAt)
  {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    OracleConfig storage config = self.configs[generationKey];
    if (!config.enabled) revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    uint8 outcomeIndex = _validateCurrentGeneration(config.key);
    _requireBeforeExpiry(config.key);

    ObservationRing storage ring = self.rings[generationKey];
    if (ring.cardinality < 2) {
      revert LibDreamMarginErrors.OracleNotReady(generationKey, 0, config.minAge);
    }
    uint256 newestAge = block.timestamp - ring.newestTimestamp;
    // Timestamp freshness is the oracle security condition being enforced.
    // forge-lint: disable-next-line(block-timestamp)
    if (newestAge > config.staleAfter) {
      revert LibDreamMarginErrors.StaleOracle(generationKey, newestAge, config.staleAfter);
    }

    MarkObservation storage newest = self.observations[generationKey][_latestIndex(ring, config)];
    uint40 target = newest.timestamp > config.minAge ? newest.timestamp - config.minAge : 0;
    bool found = false;
    MarkObservation memory anchor;
    uint16 capacity = config.maxObservations;
    for (uint16 i = 0; i < capacity; ++i) {
      MarkObservation memory candidate = self.observations[generationKey][i];
      if (
        candidate.timestamp != 0 && candidate.timestamp <= target
          && (!found || candidate.timestamp > anchor.timestamp)
      ) {
        anchor = candidate;
        found = true;
      }
    }
    if (!found) {
      uint256 retainedAge = newest.timestamp - ring.oldestTimestamp;
      revert LibDreamMarginErrors.OracleNotReady(generationKey, retainedAge, config.minAge);
    }

    age = newest.timestamp - anchor.timestamp;
    uint256 timeWeightedMark =
      LibPositionRisk.twapDown(anchor.cumulativeMarkSeconds, newest.cumulativeMarkSeconds, age);
    (,,, uint256 currentRecovery) = _sampleBook(config, generationKey, outcomeIndex);
    mark = timeWeightedMark < currentRecovery ? timeWeightedMark : currentRecovery;
    updatedAt = newest.timestamp;
  }

  /// @notice Reads, validates, transforms, and walks the bounded relevant binary book side.
  /// @param config Generation observation policy.
  /// @param generationKey Generation identifier used in depth errors.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @return bestBid Best same-outcome bid.
  /// @return depthBid Size-weighted same-outcome bid.
  /// @return oppositeAsk Size-weighted opposite-outcome ask.
  /// @return conservativeMark Larger complete executable recovery route per whole outcome.
  function _sampleBook(OracleConfig storage config, bytes32 generationKey, uint8 outcomeIndex)
    private
    view
    returns (uint256 bestBid, uint256 depthBid, uint256 oppositeAsk, uint256 conservativeMark)
  {
    RecoveryBook memory
      book = _walkRecoveryBook(config.key, outcomeIndex, config.depthQuantity, config.maxBookLevels);
    if (!book.direct.complete || !book.opposite.complete) {
      uint256 filled = book.direct.filledQuantity < book.opposite.filledQuantity
        ? book.direct.filledQuantity
        : book.opposite.filledQuantity;
      revert LibDreamMarginErrors.InsufficientBookDepth(generationKey, filled, config.depthQuantity);
    }
    bestBid = book.bestBid;
    depthBid = book.direct.averagePrice;
    oppositeAsk = book.opposite.averagePrice;
    uint256 hedgeMark = book.oneCollateral - oppositeAsk;
    conservativeMark = depthBid > hedgeMark ? depthBid : hedgeMark;
  }

  /// @notice Validates structural policy bounds before permanent registration.
  /// @param config Candidate generation policy.
  function _validatePolicy(OracleConfig calldata config) private pure {
    if (!config.enabled) revert LibDreamMarginErrors.UnsupportedGeneration(bytes32(0));
    if (config.minAge == 0) revert LibDreamMarginErrors.ZeroAmount(config.minAge);
    if (config.updateInterval == 0) revert LibDreamMarginErrors.ZeroAmount(config.updateInterval);
    if (config.staleAfter < config.updateInterval) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "STALE_AFTER", config.staleAfter, config.updateInterval
      );
    }
    if (config.depthQuantity == 0) revert LibDreamMarginErrors.ZeroAmount(config.depthQuantity);
    if (config.maxObservations < 2) {
      revert LibDreamMarginErrors.ValueOutOfBounds("MAX_OBSERVATIONS", config.maxObservations, 1);
    }
    if (config.maxObservations > LibDreamMarginConstants.MAX_OBSERVATIONS) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "MAX_OBSERVATIONS", config.maxObservations, LibDreamMarginConstants.MAX_OBSERVATIONS
      );
    }
    if (config.maxBookLevels == 0 || config.maxBookLevels > LibDreamMarginConstants.MAX_BOOK_LEVELS)
    {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "MAX_BOOK_LEVELS", config.maxBookLevels, LibDreamMarginConstants.MAX_BOOK_LEVELS
      );
    }
  }

  /// @notice Revalidates the exact generation and returns its outcome index.
  /// @param key Full registered generation tuple.
  /// @return outcomeIndex Zero for YES or one for NO.
  function _validateCurrentGeneration(MarketKey memory key)
    private
    view
    returns (uint8 outcomeIndex)
  {
    IDreamDexBinaryPool.BinaryPoolInfo memory info =
      IDreamDexBinaryPool(key.pool).getBinaryPoolParams();
    if (key.outcomeId == info.yesId) {
      outcomeIndex = 0;
    } else if (key.outcomeId == info.noId) {
      outcomeIndex = 1;
    } else {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "OUTCOME_ID", bytes32(info.yesId), bytes32(key.outcomeId)
      );
    }
    _validateGeneration(_MODULE, key, outcomeIndex, true);
  }

  /// @notice Rejects observations and risk-increasing reads at or after expiry.
  /// @param key Generation whose market expiry is read.
  function _requireBeforeExpiry(MarketKey storage key) private view {
    IDreamDexBinaryPool.BinaryPoolInfo memory info =
      IDreamDexBinaryPool(key.pool).getBinaryPoolParams();
    uint256 expiry = IDreamDexBinaryMarket(info.market).expiry();
    // Market expiry is a security boundary for risk-increasing oracle reads.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp >= expiry) {
      revert LibDreamMarginErrors.MarketExpired(expiry, block.timestamp);
    }
  }

  /// @notice Returns the newest initialized physical ring index.
  /// @param ring Current ring metadata.
  /// @param config Current observation policy.
  /// @return index Newest physical index.
  function _latestIndex(ObservationRing storage ring, OracleConfig storage config)
    private
    view
    returns (uint16 index)
  {
    index = ring.nextIndex == 0 ? config.maxObservations - 1 : ring.nextIndex - 1;
  }

  /// @notice Checks the immutable configurator authority.
  function _checkConfigurator() private view {
    if (msg.sender != _CONFIGURATOR) {
      revert LibDreamMarginErrors.NotConfigurator(msg.sender, _CONFIGURATOR);
    }
  }

  /// @notice Narrows a value only after checking the observation field bound.
  /// @param field Observation field identifier.
  /// @param value Value narrowed.
  /// @return narrowed Checked 128-bit value.
  function _uint128(bytes32 field, uint256 value) private pure returns (uint128 narrowed) {
    if (value > type(uint128).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds(field, value, type(uint128).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    narrowed = uint128(value);
  }

  /// @notice Narrows the current timestamp after checking the observation field bound.
  /// @return timestamp Checked forty-bit timestamp.
  function _timestamp40() private view returns (uint40 timestamp) {
    // Timestamp manipulation cannot approach the forty-bit representational bound.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > type(uint40).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("TIMESTAMP", block.timestamp, type(uint40).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    timestamp = uint40(block.timestamp);
  }
}
