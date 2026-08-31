// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller
/// @author DreamMargin contributors
/// @notice Binds protocol dependencies and governs roles, modes, and exact market generations.
/// @dev Lifecycle entrypoints are composed in later modules; all mutable shell state is namespaced.

import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
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
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

/// @notice Administrative controller shell statically composed with the DreamDEX adapter.
abstract contract DreamMarginController is PositionOpen {
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
  /// @param initialRoles Separated initial administrative accounts.
  /// @param globalRisk Initial global debt, loss, utilization, and delay bounds.
  constructor(
    address module_,
    address vault_,
    address oracle_,
    address feeRecipient_,
    InitialRoles memory initialRoles,
    GlobalRiskConfig memory globalRisk
  ) {
    _nonzero(module_, "MODULE");
    _nonzero(vault_, "VAULT");
    _nonzero(oracle_, "ORACLE");
    if (feeRecipient_ == address(0)) {
      revert LibDreamMarginErrors.ZeroAddress("FEE_RECIPIENT");
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

    _MODULE = module_;
    _VAULT = vault_;
    _ORACLE = oracle_;
    _FEE_RECIPIENT = feeRecipient_;

    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    self.globalRisk = globalRisk;
    self.nextPositionId = LibDreamMarginConstants.FIRST_POSITION_ID;
    self.mode = ProtocolMode.ACTIVE;
    self.reentrancyStatus = LibDreamMarginConstants.REENTRANCY_UNLOCKED;
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

  /// @inheritdoc PositionOpen
  function _moduleAddress() internal view override returns (address module_) {
    module_ = _MODULE;
  }

  /// @inheritdoc PositionOpen
  function _vaultAddress() internal view override returns (address vault_) {
    vault_ = _VAULT;
  }

  /// @inheritdoc PositionOpen
  function _oracleAddress() internal view override returns (address oracle_) {
    oracle_ = _ORACLE;
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
  function getPosition(uint256 positionId) external view returns (Position memory position) {
    position = LibDreamMarginStorage.get().positions[positionId];
    if (position.owner == address(0)) revert LibDreamMarginErrors.PositionNotFound(positionId);
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
    emit GenerationUpdated(generationKey, config.enabled, config.frozen);
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
  function _validateRisk(RiskConfig calldata risk, uint16 oracleBookLevels) private view {
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
}
