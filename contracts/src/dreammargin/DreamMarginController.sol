// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller
/// @author DreamMargin contributors
/// @notice Binds protocol dependencies and governs roles, modes, and exact market generations.
/// @dev Lifecycle entrypoints are composed in later modules; all mutable shell state is namespaced.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamMarginVault} from "src/interfaces/dreammargin/IDreamMarginVault.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  LibDreamMarginStorage,
  MarketKey,
  PendingChange,
  Position,
  ProtocolMode,
  RiskConfig,
  SeriesOracleConfig,
  SeriesPolicy
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

/// @notice Administrative controller shell statically composed with the DreamDEX adapter.
contract DreamMarginController is IDreamMarginController, DreamDexAdapter {
  /// @notice Mask containing every role bit recognized by this deployment.
  uint256 private constant _ALL_ROLES = LibDreamMarginConstants.ROLE_GOVERNANCE
    | LibDreamMarginConstants.ROLE_RISK_STEWARD | LibDreamMarginConstants.ROLE_GUARDIAN
    | LibDreamMarginConstants.ROLE_FEE_COLLECTOR | LibDreamMarginConstants.ROLE_KEEPER;

  /// @notice Immutable DreamDEX binary module.
  address private immutable _MODULE;

  /// @notice Immutable collateral vault.
  address private immutable _VAULT;

  /// @notice Immutable generation-bound mark oracle.
  address private immutable _ORACLE;

  /// @notice Immutable destination for already-accrued protocol fees.
  address private immutable _FEE_RECIPIENT;

  /// @notice Immutable opening lifecycle facet reached only by its two explicit wrappers.
  address private immutable _POSITION_OPEN_FACET;

  /// @notice Immutable ordinary-reduction facet reached only by its four explicit wrappers.
  address private immutable _POSITION_CLOSE_FACET;

  /// @notice Immutable liquidation facet reached only by its explicit wrapper.
  address private immutable _POSITION_LIQUIDATION_FACET;

  /// @notice Immutable terminal-settlement facet reached only by its explicit wrappers.
  address private immutable _POSITION_SETTLEMENT_FACET;

  /// @notice Initial separated administrative accounts.
  /// @param governance Account scheduling high-impact delayed changes.
  /// @param riskSteward Account assigned bounded risk-steward authority.
  /// @param guardian Account assigned immediate restrictive emergency authority.
  /// @param feeCollector Account assigned fee-forwarding authority.
  struct InitialRoles {
    address governance;
    address riskSteward;
    address guardian;
    address feeCollector;
  }

  /// @notice Binds immutable dependencies and initializes roles and global safety bounds once.
  /// @param module_ DreamDEX binary module.
  /// @param vault_ Collateral vault whose immutable controller must be this deployment.
  /// @param oracle_ Mark oracle whose configurator and module must match this deployment.
  /// @param feeRecipient_ Immutable fee destination.
  /// @param positionOpenFacet_ Predeployed immutable opening facet.
  /// @param positionCloseFacet_ Predeployed immutable ordinary-reduction facet.
  /// @param positionLiquidationFacet_ Predeployed immutable liquidation facet.
  /// @param positionSettlementFacet_ Predeployed immutable terminal-settlement facet.
  /// @param initialRoles Separated initial administrative accounts.
  /// @param globalRisk Initial global debt, loss, utilization, and delay bounds.
  constructor(
    address module_,
    address vault_,
    address oracle_,
    address feeRecipient_,
    address positionOpenFacet_,
    address positionCloseFacet_,
    address positionLiquidationFacet_,
    address positionSettlementFacet_,
    InitialRoles memory initialRoles,
    GlobalRiskConfig memory globalRisk
  ) {
    _nonzero(module_, "MODULE");
    _nonzero(vault_, "VAULT");
    _nonzero(oracle_, "ORACLE");
    if (feeRecipient_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("FEE_RECIPIENT");
    }
    if (positionOpenFacet_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("POSITION_OPEN_FACET");
    }
    if (positionCloseFacet_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("POSITION_CLOSE_FACET");
    }
    if (positionLiquidationFacet_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("POSITION_LIQUIDATION_FACET");
    }
    if (positionSettlementFacet_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("POSITION_SETTLEMENT_FACET");
    }
    _nonzero(initialRoles.governance, "GOVERNANCE");
    _nonzero(initialRoles.riskSteward, "RISK_STEWARD");
    _nonzero(initialRoles.guardian, "GUARDIAN");
    _nonzero(initialRoles.feeCollector, "FEE_COLLECTOR");
    _validateGlobalRisk(globalRisk);

    if (IDreamMarginVault(vault_).controller() != address(this)) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "VAULT_CONTROLLER",
        bytes32(uint256(uint160(address(this)))),
        bytes32(uint256(uint160(IDreamMarginVault(vault_).controller())))
      );
    }
    if (IDreamDexMarkOracle(oracle_).configurator() != address(this)) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "ORACLE_CONFIGURATOR",
        bytes32(uint256(uint160(address(this)))),
        bytes32(uint256(uint160(IDreamDexMarkOracle(oracle_).configurator())))
      );
    }
    if (IDreamDexMarkOracle(oracle_).module() != module_) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "ORACLE_MODULE",
        bytes32(uint256(uint160(module_))),
        bytes32(uint256(uint160(IDreamDexMarkOracle(oracle_).module())))
      );
    }
    if (positionOpenFacet_.code.length == 0) {
      revert LibDreamMarginErrors.InvalidFacet(positionOpenFacet_);
    }
    if (positionCloseFacet_.code.length == 0) {
      revert LibDreamMarginErrors.InvalidFacet(positionCloseFacet_);
    }
    if (positionLiquidationFacet_.code.length == 0) {
      revert LibDreamMarginErrors.InvalidFacet(positionLiquidationFacet_);
    }
    if (positionSettlementFacet_.code.length == 0) {
      revert LibDreamMarginErrors.InvalidFacet(positionSettlementFacet_);
    }

    _MODULE = module_;
    _VAULT = vault_;
    _ORACLE = oracle_;
    _FEE_RECIPIENT = feeRecipient_;
    _POSITION_OPEN_FACET = positionOpenFacet_;
    _POSITION_CLOSE_FACET = positionCloseFacet_;
    _POSITION_LIQUIDATION_FACET = positionLiquidationFacet_;
    _POSITION_SETTLEMENT_FACET = positionSettlementFacet_;

    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    self.globalRisk = globalRisk;
    self.nextPositionId = LibDreamMarginConstants.FIRST_POSITION_ID;
    self.mode = ProtocolMode.ACTIVE;
    self.initialized = true;
    _assignInitialRole(self, initialRoles.governance, LibDreamMarginConstants.ROLE_GOVERNANCE);
    _assignInitialRole(self, initialRoles.riskSteward, LibDreamMarginConstants.ROLE_RISK_STEWARD);
    _assignInitialRole(self, initialRoles.guardian, LibDreamMarginConstants.ROLE_GUARDIAN);
    _assignInitialRole(self, initialRoles.feeCollector, LibDreamMarginConstants.ROLE_FEE_COLLECTOR);
  }

  /// @inheritdoc IDreamMarginController
  function module() external view returns (address module_) {
    module_ = _MODULE;
  }

  /// @inheritdoc IDreamMarginController
  function vault() external view returns (address vault_) {
    vault_ = _VAULT;
  }

  /// @inheritdoc IDreamMarginController
  function oracle() external view returns (address oracle_) {
    oracle_ = _ORACLE;
  }

  /// @inheritdoc IDreamMarginController
  function feeRecipient() external view returns (address recipient) {
    recipient = _FEE_RECIPIENT;
  }

  /// @inheritdoc IDreamMarginController
  function positionOpenFacet() external view returns (address facet) {
    facet = _POSITION_OPEN_FACET;
  }

  /// @inheritdoc IDreamMarginController
  function positionCloseFacet() external view returns (address facet) {
    facet = _POSITION_CLOSE_FACET;
  }

  /// @inheritdoc IDreamMarginController
  function positionLiquidationFacet() external view returns (address facet) {
    facet = _POSITION_LIQUIDATION_FACET;
  }

  /// @inheritdoc IDreamMarginController
  function positionSettlementFacet() external view returns (address facet) {
    facet = _POSITION_SETTLEMENT_FACET;
  }

  /// @inheritdoc IDreamMarginController
  function openPosition(OpenParams calldata) external returns (uint256, uint256, uint256) {
    _delegateLifecycle(_POSITION_OPEN_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function addCollateral(uint256, uint256) external {
    _delegateLifecycle(_POSITION_OPEN_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function repay(uint256, uint256) external returns (uint256) {
    _delegateLifecycle(_POSITION_CLOSE_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function withdrawCollateral(uint256, uint256) external {
    _delegateLifecycle(_POSITION_CLOSE_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function deleverage(DeleverageParams calldata) external returns (uint256, uint256) {
    _delegateLifecycle(_POSITION_CLOSE_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function close(CloseParams calldata) external returns (uint256, uint256) {
    _delegateLifecycle(_POSITION_CLOSE_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function liquidate(LiquidationParams calldata) external returns (uint256, uint256, uint256) {
    _delegateLifecycle(_POSITION_LIQUIDATION_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function settle(uint256) external returns (uint256, uint256, uint256) {
    _delegateLifecycle(_POSITION_SETTLEMENT_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function fundReserve(uint256) external returns (uint256) {
    _delegateLifecycle(_POSITION_SETTLEMENT_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function recordRecovery(uint256) external {
    _delegateLifecycle(_POSITION_SETTLEMENT_FACET);
  }

  /// @inheritdoc IDreamMarginController
  function rolesOf(address account) external view returns (uint256 roles) {
    roles = LibDreamMarginStorage.get().roles[account];
  }

  /// @inheritdoc IDreamMarginController
  function globalRiskConfig() external view returns (GlobalRiskConfig memory config) {
    config = LibDreamMarginStorage.get().globalRisk;
  }

  /// @inheritdoc IDreamMarginController
  function protocolMode() external view returns (ProtocolMode mode) {
    mode = LibDreamMarginStorage.get().mode;
  }

  /// @inheritdoc IDreamMarginController
  function lossState()
    external
    view
    returns (uint256 dailyLoss, uint40 windowStartedAt, uint40 reduceOnlyTriggeredAt)
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    dailyLoss = self.dailyRealizedLoss;
    windowStartedAt = self.lossWindowStartedAt;
    reduceOnlyTriggeredAt = self.reduceOnlyTriggeredAt;
  }

  /// @inheritdoc IDreamMarginController
  function getPosition(uint256 positionId) external view returns (Position memory position) {
    position = LibDreamMarginStorage.get().positions[positionId];
    if (position.owner == address(0)) revert LibDreamMarginErrors.PositionNotFound(positionId);
  }

  /// @inheritdoc IDreamMarginController
  function positionsOf(address owner, uint256 offset, uint256 limit)
    external
    view
    returns (uint256[] memory ids, uint256 total)
  {
    if (limit > LibDreamMarginConstants.MAX_POSITION_PAGE_SIZE) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "POSITION_PAGE_LIMIT", limit, LibDreamMarginConstants.MAX_POSITION_PAGE_SIZE
      );
    }
    uint256[] storage positionIds = LibDreamMarginStorage.get().ownerPositionIds[owner];
    total = positionIds.length;
    if (offset >= total || limit == 0) return (new uint256[](0), total);

    uint256 length = total - offset;
    if (length > limit) length = limit;
    ids = new uint256[](length);
    for (uint256 i = 0; i < length; ++i) {
      ids[i] = positionIds[offset + i];
    }
  }

  /// @inheritdoc IDreamMarginController
  function getGeneration(bytes32 generationKey)
    external
    view
    returns (GenerationConfig memory config)
  {
    config = LibDreamMarginStorage.get().generations[generationKey];
  }

  /// @inheritdoc IDreamMarginController
  function getSeriesPolicy(bytes32 policyId) external view returns (SeriesPolicy memory policy) {
    policy = LibDreamMarginStorage.get().seriesPolicies[policyId];
  }

  /// @inheritdoc IDreamMarginController
  function policyFor(bytes32 marketId) external view returns (bytes32 policyId, bool eligible) {
    ModuleMarket memory market_ = _readModuleMarket(_MODULE, marketId);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    policyId = self.policyIdsByIdentity[_seriesIdentity(market_)];
    if (policyId == bytes32(0)) return (policyId, eligible);
    SeriesPolicy storage policy = self.seriesPolicies[policyId];
    eligible = policy.enabled && !policy.frozen && market_.outcomeSlotCount == 2
      && market_.expiry > market_.tradingStart
      && uint256(market_.expiry) - market_.tradingStart >= policy.minIntervalSec;
  }

  /// @inheritdoc IDreamMarginController
  function policyForGeneration(bytes32 generationKey) external view returns (bytes32 policyId) {
    policyId = LibDreamMarginStorage.get().generationPolicies[generationKey];
  }

  /// @inheritdoc IDreamMarginController
  function scheduleChange(bytes32 changeId, bytes32 payloadHash) external {
    _requireRole(LibDreamMarginConstants.ROLE_GOVERNANCE);
    _recordChange(changeId, payloadHash);
  }

  /// @inheritdoc IDreamMarginController
  function scheduleGenerationChange(
    bytes32 changeId,
    bytes32 generationKey,
    GenerationConfig calldata config,
    OracleConfig calldata oracleConfig
  ) external {
    _requireAnyRole(
      LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_RISK_STEWARD
    );
    bytes32 payloadHash = keccak256(
      abi.encode(this.executeGenerationChange.selector, generationKey, config, oracleConfig)
    );
    _recordChange(changeId, payloadHash);
  }

  /// @inheritdoc IDreamMarginController
  function scheduleSeriesPolicyChange(
    bytes32 changeId,
    bytes32 policyId,
    SeriesPolicy calldata policy
  ) external {
    _requireAnyRole(
      LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_RISK_STEWARD
    );
    bytes32 payloadHash =
      keccak256(abi.encode(this.executeSeriesPolicyChange.selector, policyId, policy));
    _recordChange(changeId, payloadHash);
  }

  /// @notice Records a unique delayed payload using the current caller as proposer.
  /// @param changeId Unique pending change identifier.
  /// @param payloadHash Exact execution payload commitment.
  function _recordChange(bytes32 changeId, bytes32 payloadHash) private {
    if (payloadHash == bytes32(0)) revert LibDreamMarginErrors.ZeroAmount(0);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (self.pendingChanges[changeId].proposer != address(0)) {
      revert LibDreamMarginErrors.ChangeAlreadyScheduled(changeId);
    }
    uint40 executableAt = _timestampAfter(self.globalRisk.governanceDelay);
    self.pendingChanges[changeId] =
      PendingChange({payloadHash: payloadHash, executableAt: executableAt, proposer: msg.sender});
    emit ChangeScheduled(changeId, payloadHash, executableAt);
  }

  /// @inheritdoc IDreamMarginController
  function cancelChange(bytes32 changeId) external {
    _requireAnyRole(LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_GUARDIAN);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (self.pendingChanges[changeId].proposer == address(0)) {
      revert LibDreamMarginErrors.ChangeNotScheduled(changeId);
    }
    delete self.pendingChanges[changeId];
    emit ChangeCancelled(changeId, msg.sender);
  }

  /// @inheritdoc IDreamMarginController
  function setEmergencyMode(ProtocolMode mode) external {
    _requireAnyRole(LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_GUARDIAN);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    ProtocolMode current = self.mode;
    if (uint8(mode) <= uint8(current)) {
      revert LibDreamMarginErrors.UnsafeModeTransition(uint8(current), uint8(mode));
    }
    self.mode = mode;
    emit ProtocolModeUpdated(current, mode, msg.sender);
  }

  /// @inheritdoc IDreamMarginController
  function freezeGeneration(bytes32 generationKey) external {
    _requireAnyRole(LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_GUARDIAN);
    GenerationConfig storage config = LibDreamMarginStorage.get().generations[generationKey];
    if (config.key.pool == address(0)) {
      revert LibDreamMarginErrors.UnsupportedGeneration(generationKey);
    }
    config.frozen = true;
    config.enabled = false;
    emit GenerationFrozen(generationKey, msg.sender);
  }

  /// @inheritdoc IDreamMarginController
  function freezeSeriesPolicy(bytes32 policyId) external {
    _requireAnyRole(LibDreamMarginConstants.ROLE_GOVERNANCE | LibDreamMarginConstants.ROLE_GUARDIAN);
    SeriesPolicy storage policy = LibDreamMarginStorage.get().seriesPolicies[policyId];
    if (policy.creator == address(0)) {
      revert LibDreamMarginErrors.UnsupportedSeriesPolicy(policyId);
    }
    policy.frozen = true;
    policy.enabled = false;
    emit SeriesPolicyFrozen(policyId, msg.sender);
  }

  /// @inheritdoc IDreamMarginController
  function executeRoleChange(bytes32 changeId, address account, uint256 roles) external {
    _nonzero(account, "ROLE_ACCOUNT");
    if (roles & ~_ALL_ROLES != 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("ROLES", roles, _ALL_ROLES);
    }
    bytes32 payloadHash = keccak256(abi.encode(this.executeRoleChange.selector, account, roles));
    _consumeChange(changeId, payloadHash);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    uint256 previous = self.roles[account];
    self.roles[account] = roles;
    emit RolesUpdated(account, previous, roles);
  }

  /// @inheritdoc IDreamMarginController
  function executeGlobalRiskChange(bytes32 changeId, GlobalRiskConfig calldata config) external {
    _validateGlobalRisk(config);
    bytes32 payloadHash = keccak256(abi.encode(this.executeGlobalRiskChange.selector, config));
    _consumeChange(changeId, payloadHash);
    LibDreamMarginStorage.get().globalRisk = config;
  }

  /// @inheritdoc IDreamMarginController
  function executeGenerationChange(
    bytes32 changeId,
    bytes32 generationKey,
    GenerationConfig calldata config,
    OracleConfig calldata oracleConfig
  ) external {
    bytes32 payloadHash = keccak256(
      abi.encode(this.executeGenerationChange.selector, generationKey, config, oracleConfig)
    );
    _consumeChange(changeId, payloadHash);
    _validateGenerationConfig(generationKey, config, oracleConfig);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    bool firstRegistration = self.generations[generationKey].key.pool == address(0);
    if (firstRegistration) {
      IDreamDexMarkOracle(_ORACLE).configureGeneration(generationKey, oracleConfig);
    }
    self.generations[generationKey] = config;
    delete self.generationPolicies[generationKey];
    emit GenerationUpdated(generationKey, config.enabled, config.frozen);
  }

  /// @inheritdoc IDreamMarginController
  function executeSeriesPolicyChange(
    bytes32 changeId,
    bytes32 policyId,
    SeriesPolicy calldata policy
  ) external {
    bytes32 payloadHash = keccak256(
      abi.encode(this.executeSeriesPolicyChange.selector, policyId, policy)
    );
    _consumeChange(changeId, payloadHash);
    _validateSeriesPolicy(policyId, policy);

    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    SeriesPolicy storage previous = self.seriesPolicies[policyId];
    if (previous.creator != address(0)) {
      bytes32 previousIdentity = _seriesIdentity(
        previous.creator, previous.originVenueId, previous.originOperatorId, previous.collateral
      );
      if (self.policyIdsByIdentity[previousIdentity] == policyId) {
        delete self.policyIdsByIdentity[previousIdentity];
      }
    }

    bytes32 identity = _seriesIdentity(
      policy.creator, policy.originVenueId, policy.originOperatorId, policy.collateral
    );
    bytes32 claimedBy = self.policyIdsByIdentity[identity];
    if (claimedBy != bytes32(0) && claimedBy != policyId) {
      revert LibDreamMarginErrors.SeriesPolicyIdentityClaimed(identity, claimedBy);
    }
    self.seriesPolicies[policyId] = policy;
    self.policyIdsByIdentity[identity] = policyId;
    emit SeriesPolicyUpdated(policyId, identity, policy.enabled, policy.frozen);
  }

  /// @inheritdoc IDreamMarginController
  function activateSeriesGeneration(MarketKey calldata key, uint8 outcomeIndex)
    external
    returns (bytes32 generationKey, bytes32 policyId)
  {
    MarketKey memory generationKeyData = key;
    generationKey = LibDreamMarginStorage.generationKey(generationKeyData);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (self.generations[generationKey].key.pool != address(0)) {
      revert LibDreamMarginErrors.GenerationAlreadyConfigured(generationKey);
    }

    ModuleMarket memory market_ = _readModuleMarket(_MODULE, key.marketId);
    bytes32 identity = _seriesIdentity(market_);
    policyId = self.policyIdsByIdentity[identity];
    if (policyId == bytes32(0)) {
      revert LibDreamMarginErrors.UnsupportedSeriesIdentity(identity);
    }
    SeriesPolicy storage policy = self.seriesPolicies[policyId];
    if (policy.frozen) revert LibDreamMarginErrors.SeriesPolicyFrozen(policyId);
    if (!policy.enabled) revert LibDreamMarginErrors.UnsupportedSeriesPolicy(policyId);
    if (market_.outcomeSlotCount != 2) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "OUTCOME_SLOT_COUNT", market_.outcomeSlotCount, 2
      );
    }
    uint256 interval =
      market_.expiry > market_.tradingStart ? uint256(market_.expiry) - market_.tradingStart : 0;
    if (interval < policy.minIntervalSec) {
      revert LibDreamMarginErrors.SeriesIntervalTooShort(
        key.marketId, interval, policy.minIntervalSec
      );
    }

    _validateGeneration(_MODULE, generationKeyData, outcomeIndex, true);
    RiskConfig memory risk = policy.risk;
    risk.outcomeIndex = outcomeIndex;
    _validateRisk(risk, policy.oracle.maxBookLevels);
    GenerationConfig memory generation = GenerationConfig({
      key: generationKeyData,
      risk: risk,
      marketGroup: _seriesMarketGroup(generationKeyData),
      enabled: true,
      frozen: false
    });
    OracleConfig memory oracleConfig = OracleConfig({
      key: generationKeyData,
      minAge: policy.oracle.minAge,
      updateInterval: policy.oracle.updateInterval,
      staleAfter: policy.oracle.staleAfter,
      depthQuantity: policy.oracle.depthQuantity,
      maxObservations: policy.oracle.maxObservations,
      maxBookLevels: policy.oracle.maxBookLevels,
      enabled: true
    });
    IDreamDexMarkOracle(_ORACLE).configureGeneration(generationKey, oracleConfig);
    self.generations[generationKey] = generation;
    self.generationPolicies[generationKey] = policyId;
    emit GenerationUpdated(generationKey, true, false);
    emit SeriesGenerationActivated(generationKey, policyId, generation.marketGroup, outcomeIndex);
  }

  /// @notice Validates one delayed reusable origin, risk, and oracle policy.
  /// @param policyId Nonzero governance-selected identifier.
  /// @param policy Candidate reusable policy.
  function _validateSeriesPolicy(bytes32 policyId, SeriesPolicy calldata policy) private view {
    if (policyId == bytes32(0)) revert LibDreamMarginErrors.ZeroAmount(0);
    _nonzero(policy.creator, "SERIES_CREATOR");
    _nonzero(policy.collateral, "SERIES_COLLATERAL");
    address asset = IDreamMarginVault(_VAULT).asset();
    if (policy.collateral != asset) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "VAULT_ASSET",
        bytes32(uint256(uint160(asset))),
        bytes32(uint256(uint160(policy.collateral)))
      );
    }
    if (policy.risk.outcomeIndex != 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "POLICY_OUTCOME_INDEX", policy.risk.outcomeIndex, 0
      );
    }
    _validateSeriesOracle(policy.oracle);
    _validateRisk(policy.risk, policy.oracle.maxBookLevels);
    uint256 minimumInterval = uint256(policy.risk.openingCutoff) + uint256(policy.oracle.minAge) + 1;
    if (policy.minIntervalSec < minimumInterval) {
      revert LibDreamMarginErrors.SeriesIntervalTooShort(
        bytes32(0), policy.minIntervalSec, minimumInterval
      );
    }
  }

  /// @notice Validates the keyless oracle template before it can admit future generations.
  /// @param config Candidate bounded observation template.
  function _validateSeriesOracle(SeriesOracleConfig calldata config) private pure {
    if (config.minAge == 0) revert LibDreamMarginErrors.ZeroAmount(config.minAge);
    if (config.updateInterval == 0) {
      revert LibDreamMarginErrors.ZeroAmount(config.updateInterval);
    }
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

  /// @notice Hashes the origin fields that grant one creator continuing admission authority.
  /// @param creator DreamDEX market creator.
  /// @param venueId DreamDEX venue identifier.
  /// @param operatorId DreamDEX operator identifier.
  /// @param collateral Required market collateral.
  /// @return identity Collision-resistant reusable-policy lookup key.
  function _seriesIdentity(address creator, bytes32 venueId, uint32 operatorId, address collateral)
    private
    pure
    returns (bytes32 identity)
  {
    identity = keccak256(abi.encode(creator, venueId, operatorId, collateral));
  }

  /// @notice Hashes one module record's reusable origin fields.
  /// @param market_ Complete current module market record.
  /// @return identity Collision-resistant reusable-policy lookup key.
  function _seriesIdentity(ModuleMarket memory market_) private pure returns (bytes32 identity) {
    identity = _seriesIdentity(
      market_.creator, market_.originVenueId, market_.originOperatorId, market_.collateral
    );
  }

  /// @notice Derives the exposure bucket shared by both outcomes of one recyclable generation.
  /// @param key Exact activated generation tuple.
  /// @return marketGroup Generation-scoped market exposure identifier.
  function _seriesMarketGroup(MarketKey memory key) private pure returns (bytes32 marketGroup) {
    marketGroup = keccak256(
      abi.encode("DREAM_MARGIN_SERIES_GENERATION", key.marketId, key.pool, key.marketNonce)
    );
  }

  /// @inheritdoc IDreamMarginController
  function executeModeChange(bytes32 changeId, ProtocolMode mode) external {
    bytes32 payloadHash = keccak256(abi.encode(this.executeModeChange.selector, mode));
    _consumeChange(changeId, payloadHash);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (mode == ProtocolMode.ACTIVE && self.reduceOnlyTriggeredAt != 0) {
      uint256 executableAt = self.reduceOnlyTriggeredAt + self.globalRisk.lossCooldown;
      // Cool-down timestamp enforcement is the security condition under test.
      // forge-lint: disable-next-line(block-timestamp)
      if (block.timestamp < executableAt) {
        revert LibDreamMarginErrors.ChangeNotReady(changeId, executableAt, block.timestamp);
      }
    }
    ProtocolMode previous = self.mode;
    self.mode = mode;
    emit ProtocolModeUpdated(previous, mode, msg.sender);
  }

  /// @inheritdoc IDreamMarginController
  function executeReserveWithdrawal(bytes32 changeId, uint256 assets)
    external
    returns (uint256 reserveSharesBurned)
  {
    if (assets == 0) revert LibDreamMarginErrors.ZeroAmount(assets);
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    if (self.mode != ProtocolMode.PAUSED) {
      revert LibDreamMarginErrors.ActionBlocked(
        uint8(self.mode), this.executeReserveWithdrawal.selector
      );
    }
    bytes32 payloadHash = keccak256(abi.encode(this.executeReserveWithdrawal.selector, assets));
    _consumeChange(changeId, payloadHash);
    reserveSharesBurned = IDreamMarginVault(_VAULT).withdrawReserve(assets, _FEE_RECIPIENT);
    // The vault's transient lock rejects callback reentry into every vault-mutating path.
    // forge-lint: disable-next-line(reentrancy-events)
    emit ProtocolReserveWithdrawn(_FEE_RECIPIENT, assets, reserveSharesBurned);
  }

  /// @notice Verifies and consumes one mature exact payload commitment.
  /// @param changeId Pending change identifier.
  /// @param actualHash Hash of the supplied execution selector and arguments.
  function _consumeChange(bytes32 changeId, bytes32 actualHash) private {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    PendingChange memory change_ = self.pendingChanges[changeId];
    if (change_.proposer == address(0)) {
      revert LibDreamMarginErrors.ChangeNotScheduled(changeId);
    }
    if (actualHash != change_.payloadHash) {
      revert LibDreamMarginErrors.ChangePayloadMismatch(change_.payloadHash, actualHash);
    }
    // Governance-delay timestamp enforcement is the security condition under test.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp < change_.executableAt) {
      revert LibDreamMarginErrors.ChangeNotReady(changeId, change_.executableAt, block.timestamp);
    }
    delete self.pendingChanges[changeId];
    emit ChangeExecuted(changeId, actualHash);
  }

  /// @notice Validates one generation policy and all cross-contract bindings.
  /// @param generationKey Expected full generation identifier.
  /// @param config Controller risk policy.
  /// @param oracleConfig Immutable first-registration observation policy.
  function _validateGenerationConfig(
    bytes32 generationKey,
    GenerationConfig calldata config,
    OracleConfig calldata oracleConfig
  ) private view {
    MarketKey memory key = config.key;
    bytes32 derived = LibDreamMarginStorage.generationKey(key);
    if (derived != generationKey) {
      revert LibDreamMarginErrors.GenerationMismatch(generationKey, derived);
    }
    MarketKey memory oracleKey = oracleConfig.key;
    bytes32 oracleDerived = LibDreamMarginStorage.generationKey(oracleKey);
    if (oracleDerived != generationKey) {
      revert LibDreamMarginErrors.GenerationMismatch(generationKey, oracleDerived);
    }
    if (config.marketGroup == bytes32(0)) revert LibDreamMarginErrors.ZeroAmount(0);
    if (key.collateral != IDreamMarginVault(_VAULT).asset()) {
      revert LibDreamMarginErrors.IntegrationValueMismatch(
        "VAULT_ASSET",
        bytes32(uint256(uint160(IDreamMarginVault(_VAULT).asset()))),
        bytes32(uint256(uint160(key.collateral)))
      );
    }
    _validateRisk(config.risk, oracleConfig.maxBookLevels);
    _validateGeneration(_MODULE, key, config.risk.outcomeIndex, true);
  }

  /// @notice Validates one per-generation risk record against structural and global bounds.
  /// @param risk Candidate risk policy.
  /// @param oracleBookLevels Immutable oracle book-walk bound.
  function _validateRisk(RiskConfig memory risk, uint16 oracleBookLevels) private view {
    GlobalRiskConfig storage globalRisk = LibDreamMarginStorage.get().globalRisk;
    if (
      risk.maxDebtPerPosition == 0 || risk.maxDebtPerPosition > risk.maxDebtPerOutcome
        || risk.maxDebtPerOutcome > risk.maxDebtPerMarket
        || risk.maxDebtPerMarket > globalRisk.maxDebtGlobal
    ) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "DEBT_HIERARCHY", risk.maxDebtPerMarket, globalRisk.maxDebtGlobal
      );
    }
    if (risk.minDebt == 0 || risk.minDebt > risk.maxDebtPerPosition) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "MIN_DEBT", risk.minDebt, risk.maxDebtPerPosition
      );
    }
    _bps("INITIAL_LTV", risk.initialLtvBps);
    _bps("MAINTENANCE_LTV", risk.maintenanceLtvBps);
    _bps("COLLATERAL_FACTOR", risk.collateralFactorBps);
    _bps("LIQUIDATION_BONUS", risk.liquidationBonusBps);
    _bps("MAX_SPREAD", risk.maxSpreadBps);
    _bps("MAX_SLIPPAGE", risk.maxSlippageBps);
    _bps("MAX_POSITION_DEPTH", risk.maxPositionDepthBps);
    if (risk.initialLtvBps > risk.maintenanceLtvBps) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "INITIAL_LTV", risk.initialLtvBps, risk.maintenanceLtvBps
      );
    }
    if (risk.maxLeverageBps < LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "MAX_LEVERAGE", risk.maxLeverageBps, LibDreamMarginConstants.BPS
      );
    }
    if (risk.openingCutoff < risk.reduceOnlyCutoff) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "OPENING_CUTOFF", risk.openingCutoff, risk.reduceOnlyCutoff
      );
    }
    if (risk.compressionWindow == 0) {
      revert LibDreamMarginErrors.ZeroAmount(risk.compressionWindow);
    }
    if (
      risk.maxBookLevels == 0 || risk.maxBookLevels > LibDreamMarginConstants.MAX_BOOK_LEVELS
        || risk.maxBookLevels != oracleBookLevels
    ) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "MAX_BOOK_LEVELS", risk.maxBookLevels, oracleBookLevels
      );
    }
    uint8 decimals = IERC20Minimal(IDreamMarginVault(_VAULT).asset()).decimals();
    if (risk.collateralDecimals != decimals) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "COLLATERAL_DECIMALS", risk.collateralDecimals, decimals
      );
    }
    if (risk.outcomeIndex > 1) {
      revert LibDreamMarginErrors.ValueOutOfBounds("OUTCOME_INDEX", risk.outcomeIndex, 1);
    }
  }

  /// @notice Validates global nonzero debt/loss/timing bounds and utilization basis points.
  /// @param config Candidate global risk configuration.
  function _validateGlobalRisk(GlobalRiskConfig memory config) private pure {
    if (config.maxDebtGlobal == 0) revert LibDreamMarginErrors.ZeroAmount(0);
    if (config.maxDailyRealizedLoss == 0) revert LibDreamMarginErrors.ZeroAmount(0);
    if (config.maxVaultUtilizationBps == 0) revert LibDreamMarginErrors.ZeroAmount(0);
    _bps("MAX_UTILIZATION", config.maxVaultUtilizationBps);
    if (config.governanceDelay == 0) revert LibDreamMarginErrors.ZeroAmount(0);
    if (config.lossWindow == 0) revert LibDreamMarginErrors.ZeroAmount(0);
    if (config.lossCooldown < config.governanceDelay) {
      revert LibDreamMarginErrors.ValueOutOfBounds(
        "LOSS_COOLDOWN", config.lossCooldown, config.governanceDelay
      );
    }
  }

  /// @notice Requires every bit in one role mask.
  /// @param requiredRole Required role bit.
  function _requireRole(uint256 requiredRole) private view {
    uint256 actual = LibDreamMarginStorage.get().roles[msg.sender];
    if (actual & requiredRole != requiredRole) {
      revert LibDreamMarginErrors.Unauthorized(msg.sender, requiredRole, actual);
    }
  }

  /// @notice Requires at least one role from a permitted bitmap.
  /// @param permittedRoles Bitmap of permitted role bits.
  function _requireAnyRole(uint256 permittedRoles) private view {
    uint256 actual = LibDreamMarginStorage.get().roles[msg.sender];
    if (actual & permittedRoles == 0) {
      revert LibDreamMarginErrors.Unauthorized(msg.sender, permittedRoles, actual);
    }
  }

  /// @notice ORs one initial role into an account and emits its complete bitmap.
  /// @param self Controller namespace.
  /// @param account Initial role account.
  /// @param role Role bit assigned.
  function _assignInitialRole(
    LibDreamMarginStorage.State storage self,
    address account,
    uint256 role
  ) private {
    uint256 previous = self.roles[account];
    self.roles[account] = previous | role;
    emit RolesUpdated(account, previous, previous | role);
  }

  /// @notice Rejects a basis-point value above one hundred percent.
  /// @param field Risk-field identifier.
  /// @param value Candidate basis-point value.
  function _bps(bytes32 field, uint256 value) private pure {
    if (value > LibDreamMarginConstants.BPS) {
      revert LibDreamMarginErrors.InvalidBps(field, value);
    }
  }

  /// @notice Rejects a zero dependency or account.
  /// @param account Address checked.
  /// @param field Address-field identifier.
  function _nonzero(address account, bytes32 field) private pure {
    if (account == address(0)) revert LibDreamMarginErrors.ZeroAddress(field);
  }

  /// @notice Computes a delayed timestamp after proving forty-bit representation.
  /// @param delay Delay added to current time.
  /// @return timestamp Checked executable timestamp.
  function _timestampAfter(uint40 delay) private view returns (uint40 timestamp) {
    uint256 value = block.timestamp + delay;
    // Timestamp manipulation cannot approach the forty-bit representational bound.
    // forge-lint: disable-next-line(block-timestamp)
    if (value > type(uint40).max) {
      revert LibDreamMarginErrors.ValueOutOfBounds("TIMESTAMP", value, type(uint40).max);
    }
    // The preceding bound check proves the conversion cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    timestamp = uint40(value);
  }

  /// @notice Delegates one exact lifecycle selector to its immutable facet and returns bytes.
  /// @dev Memory layout: `pointer` references temporary calldata, then ABI return bytes.
  ///      1. Copy the complete validated Solidity entrypoint calldata into free memory.
  ///      2. Delegate only to the wrapper-selected immutable lifecycle facet.
  ///      3. Copy return data over the temporary region and bubble success or revert exactly.
  ///      Safety Considerations: EVERY TARGET ARGUMENT IS LOADED FROM A CONSTRUCTOR-SET
  ///      IMMUTABLE AND NOT CALLER-CONTROLLED; CALLERS EXPOSE ONLY DECLARED INTERFACE SELECTORS;
  ///      FREE MEMORY IS ADVANCED BEFORE RETURNING SO NO LIVE SOLIDITY MEMORY IS ALIASED.
  /// @param target Wrapper-selected immutable lifecycle facet.
  function _delegateLifecycle(address target) private {
    assembly ("memory-safe") {
      let pointer := mload(0x40)
      calldatacopy(pointer, 0, calldatasize())
      let success := delegatecall(gas(), target, pointer, calldatasize(), 0, 0)
      let size := returndatasize()
      returndatacopy(pointer, 0, size)
      mstore(0x40, and(add(add(pointer, size), 31), not(31)))
      if iszero(success) { revert(pointer, size) }
      return(pointer, size)
    }
  }
}
