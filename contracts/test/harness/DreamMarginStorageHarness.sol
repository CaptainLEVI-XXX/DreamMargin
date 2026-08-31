// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin namespaced-storage test harness
/// @author DreamMargin contributors
/// @notice Exposes controller, vault, and oracle namespace fields for layout tests.
/// @dev Test-only setters deliberately omit production authorization and validation.

import {
  GenerationConfig,
  GlobalRiskConfig,
  LibDreamMarginStorage,
  MarketKey,
  PendingChange,
  Position,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibDreamMarginVaultStorage} from "src/libs/dreammargin/LibDreamMarginVaultStorage.sol";
import {
  LibDreamDexMarkOracleStorage,
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";

/// @notice Mutates all three namespaced state machines inside one test deployment.
contract DreamMarginStorageHarness {
  // -------------------------------------------------------------------------
  // Controller namespace
  // -------------------------------------------------------------------------

  /// @notice Writes one controller position record.
  /// @param positionId Position identifier.
  /// @param position Complete position record.
  function writePosition(uint256 positionId, Position calldata position) external {
    LibDreamMarginStorage.get().positions[positionId] = position;
  }

  /// @notice Reads one controller position record.
  /// @param positionId Position identifier.
  /// @return position Complete position record.
  function readPosition(uint256 positionId) external view returns (Position memory position) {
    position = LibDreamMarginStorage.get().positions[positionId];
  }

  /// @notice Writes one controller generation configuration.
  /// @param generationKey Generation identifier.
  /// @param config Complete generation configuration.
  function writeGeneration(bytes32 generationKey, GenerationConfig calldata config) external {
    LibDreamMarginStorage.get().generations[generationKey] = config;
  }

  /// @notice Reads one controller generation configuration.
  /// @param generationKey Generation identifier.
  /// @return config Complete generation configuration.
  function readGeneration(bytes32 generationKey)
    external
    view
    returns (GenerationConfig memory config)
  {
    config = LibDreamMarginStorage.get().generations[generationKey];
  }

  /// @notice Writes every scalar controller field and the global risk record.
  /// @param globalRisk Complete global risk configuration.
  /// @param totalDebtShares Aggregate controller debt shares.
  /// @param nextPositionId Next allocated position identifier.
  /// @param dailyRealizedLoss Active-window realized loss.
  /// @param lossWindowStartedAt Active loss-window start timestamp.
  /// @param reduceOnlyTriggeredAt Latest loss-triggered reduce-only timestamp.
  /// @param mode Protocol-wide operating mode.
  /// @param reentrancyStatus Reentrancy-guard state.
  /// @param initialized Initialization state.
  function writeControllerScalars(
    GlobalRiskConfig calldata globalRisk,
    uint256 totalDebtShares,
    uint256 nextPositionId,
    uint256 dailyRealizedLoss,
    uint40 lossWindowStartedAt,
    uint40 reduceOnlyTriggeredAt,
    ProtocolMode mode,
    uint8 reentrancyStatus,
    bool initialized
  ) external {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    self.globalRisk = globalRisk;
    self.totalDebtShares = totalDebtShares;
    self.nextPositionId = nextPositionId;
    self.dailyRealizedLoss = dailyRealizedLoss;
    self.lossWindowStartedAt = lossWindowStartedAt;
    self.reduceOnlyTriggeredAt = reduceOnlyTriggeredAt;
    self.mode = mode;
    self.reentrancyStatus = reentrancyStatus;
    self.initialized = initialized;
  }

  /// @notice Reads every scalar controller field and the global risk record.
  /// @return globalRisk Complete global risk configuration.
  /// @return totalDebtShares Aggregate controller debt shares.
  /// @return nextPositionId Next allocated position identifier.
  /// @return dailyRealizedLoss Active-window realized loss.
  /// @return lossWindowStartedAt Active loss-window start timestamp.
  /// @return reduceOnlyTriggeredAt Latest loss-triggered reduce-only timestamp.
  /// @return mode Protocol-wide operating mode.
  /// @return reentrancyStatus Reentrancy-guard state.
  /// @return initialized Initialization state.
  function readControllerScalars()
    external
    view
    returns (
      GlobalRiskConfig memory globalRisk,
      uint256 totalDebtShares,
      uint256 nextPositionId,
      uint256 dailyRealizedLoss,
      uint40 lossWindowStartedAt,
      uint40 reduceOnlyTriggeredAt,
      ProtocolMode mode,
      uint8 reentrancyStatus,
      bool initialized
    )
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    globalRisk = self.globalRisk;
    totalDebtShares = self.totalDebtShares;
    nextPositionId = self.nextPositionId;
    dailyRealizedLoss = self.dailyRealizedLoss;
    lossWindowStartedAt = self.lossWindowStartedAt;
    reduceOnlyTriggeredAt = self.reduceOnlyTriggeredAt;
    mode = self.mode;
    reentrancyStatus = self.reentrancyStatus;
    initialized = self.initialized;
  }

  /// @notice Writes every controller mapping category used outside composite records.
  /// @param token Outcome-token contract.
  /// @param outcomeId Exact outcome ID.
  /// @param generationKey Generation identifier.
  /// @param marketGroup Market exposure identifier.
  /// @param account Role and nonce account.
  /// @param changeId Delayed-change identifier.
  /// @param positionId Loss-finalization position identifier.
  /// @param values Attributed shares, outcome debt, market debt, roles, and nonce respectively.
  /// @param change_ Delayed governance record.
  function writeControllerMappings(
    address token,
    uint256 outcomeId,
    bytes32 generationKey,
    bytes32 marketGroup,
    address account,
    bytes32 changeId,
    uint256 positionId,
    uint256[5] calldata values,
    PendingChange calldata change_
  ) external {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    self.attributedShares[token][outcomeId] = values[0];
    self.outcomeDebtShares[generationKey] = values[1];
    self.marketDebtShares[marketGroup] = values[2];
    self.roles[account] = values[3];
    self.authorizationNonces[account] = values[4];
    self.pendingChanges[changeId] = change_;
    self.lossRecognized[positionId] = true;
  }

  /// @notice Reads every controller mapping category used outside composite records.
  /// @param token Outcome-token contract.
  /// @param outcomeId Exact outcome ID.
  /// @param generationKey Generation identifier.
  /// @param marketGroup Market exposure identifier.
  /// @param account Role and nonce account.
  /// @param changeId Delayed-change identifier.
  /// @param positionId Loss-finalization position identifier.
  /// @return values Attributed shares, outcome debt, market debt, roles, and nonce respectively.
  /// @return change_ Delayed governance record.
  /// @return lossRecognized Whether the position loss was finalized.
  function readControllerMappings(
    address token,
    uint256 outcomeId,
    bytes32 generationKey,
    bytes32 marketGroup,
    address account,
    bytes32 changeId,
    uint256 positionId
  )
    external
    view
    returns (uint256[5] memory values, PendingChange memory change_, bool lossRecognized)
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    values[0] = self.attributedShares[token][outcomeId];
    values[1] = self.outcomeDebtShares[generationKey];
    values[2] = self.marketDebtShares[marketGroup];
    values[3] = self.roles[account];
    values[4] = self.authorizationNonces[account];
    change_ = self.pendingChanges[changeId];
    lossRecognized = self.lossRecognized[positionId];
  }

  /// @notice Derives a generation key through the controller storage library.
  /// @param key Complete market-generation tuple.
  /// @return generationKey Hash of every tuple field in canonical order.
  function deriveGenerationKey(MarketKey calldata key)
    external
    pure
    returns (bytes32 generationKey)
  {
    generationKey = LibDreamMarginStorage.generationKey(key);
  }

  // -------------------------------------------------------------------------
  // Vault namespace
  // -------------------------------------------------------------------------

  /// @notice Writes vault mappings and every scalar vault field.
  /// @param account Share owner.
  /// @param spender Approved share spender.
  /// @param values Balance, allowance, supply, cash, debt, interest, debt shares, index,
  ///        locked reserve, protocol reserve, fees, realized loss, and recovery respectively.
  /// @param lastAccrual Last financing accrual timestamp.
  /// @param reentrancyStatus Reentrancy-guard state.
  /// @param initialized Initialization state.
  function writeVault(
    address account,
    address spender,
    uint256[13] calldata values,
    uint40 lastAccrual,
    uint8 reentrancyStatus,
    bool initialized
  ) external {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    self.balanceOf[account] = values[0];
    self.allowance[account][spender] = values[1];
    self.totalSupply = values[2];
    self.internalCash = values[3];
    self.performingDebt = values[4];
    self.collectibleInterest = values[5];
    self.totalDebtShares = values[6];
    self.debtIndexWad = values[7];
    self.lockedReserve = values[8];
    self.protocolReserve = values[9];
    self.accruedProtocolFees = values[10];
    self.realizedBadDebt = values[11];
    self.recoveredBadDebt = values[12];
    self.lastAccrual = lastAccrual;
    self.reentrancyStatus = reentrancyStatus;
    self.initialized = initialized;
  }

  /// @notice Reads vault mappings and every scalar vault field.
  /// @param account Share owner.
  /// @param spender Approved share spender.
  /// @return values Balance, allowance, supply, cash, debt, interest, debt shares, index,
  ///         locked reserve, protocol reserve, fees, realized loss, and recovery respectively.
  /// @return lastAccrual Last financing accrual timestamp.
  /// @return reentrancyStatus Reentrancy-guard state.
  /// @return initialized Initialization state.
  function readVault(address account, address spender)
    external
    view
    returns (
      uint256[13] memory values,
      uint40 lastAccrual,
      uint8 reentrancyStatus,
      bool initialized
    )
  {
    LibDreamMarginVaultStorage.State storage self = LibDreamMarginVaultStorage.get();
    values[0] = self.balanceOf[account];
    values[1] = self.allowance[account][spender];
    values[2] = self.totalSupply;
    values[3] = self.internalCash;
    values[4] = self.performingDebt;
    values[5] = self.collectibleInterest;
    values[6] = self.totalDebtShares;
    values[7] = self.debtIndexWad;
    values[8] = self.lockedReserve;
    values[9] = self.protocolReserve;
    values[10] = self.accruedProtocolFees;
    values[11] = self.realizedBadDebt;
    values[12] = self.recoveredBadDebt;
    lastAccrual = self.lastAccrual;
    reentrancyStatus = self.reentrancyStatus;
    initialized = self.initialized;
  }

  // -------------------------------------------------------------------------
  // Oracle namespace
  // -------------------------------------------------------------------------

  /// @notice Writes oracle configuration, ring metadata, one observation, and init state.
  /// @param generationKey Generation identifier.
  /// @param index Observation ring index.
  /// @param config Complete observation configuration.
  /// @param ring Complete ring metadata.
  /// @param observation Complete observation value.
  /// @param initialized Initialization state.
  function writeOracle(
    bytes32 generationKey,
    uint16 index,
    OracleConfig calldata config,
    ObservationRing calldata ring,
    MarkObservation calldata observation,
    bool initialized
  ) external {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    self.configs[generationKey] = config;
    self.rings[generationKey] = ring;
    self.observations[generationKey][index] = observation;
    self.initialized = initialized;
  }

  /// @notice Reads oracle configuration, ring metadata, one observation, and init state.
  /// @param generationKey Generation identifier.
  /// @param index Observation ring index.
  /// @return config Complete observation configuration.
  /// @return ring Complete ring metadata.
  /// @return observation Complete observation value.
  /// @return initialized Initialization state.
  function readOracle(bytes32 generationKey, uint16 index)
    external
    view
    returns (
      OracleConfig memory config,
      ObservationRing memory ring,
      MarkObservation memory observation,
      bool initialized
    )
  {
    LibDreamDexMarkOracleStorage.State storage self = LibDreamDexMarkOracleStorage.get();
    config = self.configs[generationKey];
    ring = self.rings[generationKey];
    observation = self.observations[generationKey][index];
    initialized = self.initialized;
  }
}
