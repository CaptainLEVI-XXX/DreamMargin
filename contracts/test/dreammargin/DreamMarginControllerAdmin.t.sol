// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller administration tests
/// @author DreamMargin contributors
/// @notice Verifies immutable bindings, separated roles, delays, modes, and generation admission.
/// @dev Named risk values are conservative test fixtures, not production parameters.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  MarketKey,
  ProtocolMode,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {DreamMarginControllerHarness} from "test/harness/DreamMarginControllerHarness.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";

// Expected-revert admin calls intentionally ignore values and fixture casts are statically bounded.
// forge-lint: disable-start(unsafe-typecast, unused-return)

/// @notice Exercises every controller-shell authority boundary against a valid local generation.
contract DreamMarginControllerAdminTest is Test {
  uint256 private constant _ONE = 1e6;
  uint256 private constant _START = 1_000_000;
  uint64 private constant _EXPIRY = 1_100_000;
  bytes32 private constant _MARKET_ID = keccak256("admin-market");
  uint256 private constant _YES_ID = 41;
  uint256 private constant _NO_ID = 42;
  address private constant _SETTLEMENT = address(0x5151);
  address private constant _GOVERNANCE = address(0x1001);
  address private constant _RISK_STEWARD = address(0x1002);
  address private constant _GUARDIAN = address(0x1003);
  address private constant _FEE_COLLECTOR = address(0x1004);
  address private constant _FEE_RECIPIENT = address(0x1005);
  address private constant _STRANGER = address(0xBAD);

  MockERC20 private _collateral;
  MockERC6909 private _outcome;
  MockDreamDexBinaryMarket private _market;
  MockDreamDexBinaryPool private _pool;
  MockDreamDexBinaryModule private _module;
  DreamMarginVault private _vault;
  DreamDexMarkOracle private _oracle;
  PositionOpen private _positionOpen;
  PositionClose private _positionClose;
  PositionLiquidation private _positionLiquidation;
  DreamMarginControllerHarness private _controller;
  MarketKey private _key;
  bytes32 private _generationKey;

  /// @notice Deploys a circular immutable vault/oracle/controller binding by predicted address.
  function setUp() external {
    vm.warp(_START);
    _collateral = new MockERC20("Admin USD", "aUSD", 6);
    _outcome = new MockERC6909();
    _market = new MockDreamDexBinaryMarket(
      address(_outcome), _YES_ID, _NO_ID, address(1), address(_collateral), _EXPIRY
    );
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: _ONE, lotSize: _ONE});
    _pool = new MockDreamDexBinaryPool(_poolInfo(), grid, _EXPIRY * 1e9);
    _market.setPool(address(_pool));
    _module = new MockDreamDexBinaryModule(_SETTLEMENT);
    _module.setMarket(_MARKET_ID, 1, _moduleMarket());
    _setBook();
    _positionOpen = new PositionOpen();
    _positionClose = new PositionClose();
    _positionLiquidation = new PositionLiquidation();

    uint256 nextNonce = vm.getNonce(address(this));
    address predictedController = vm.computeCreateAddress(address(this), nextNonce + 2);
    _vault = new DreamMarginVault(address(_collateral), predictedController, 0.1e18);
    _oracle = new DreamDexMarkOracle(address(_module), predictedController);
    _controller = new DreamMarginControllerHarness(
      address(_module),
      address(_vault),
      address(_oracle),
      _FEE_RECIPIENT,
      address(_positionOpen),
      address(_positionClose),
      address(_positionLiquidation),
      _initialRoles(),
      _globalRisk()
    );
    assertEq(address(_controller), predictedController);
    _key =
      MarketKey(_MARKET_ID, address(_pool), 1, address(_outcome), _YES_ID, address(_collateral));
    _generationKey = _deriveKey(_key);
  }

  /// @notice Initializes immutable dependencies, role separation, sentinel IDs, and active mode.
  function test_deploymentBindsDependenciesAndRoles() external view {
    assertEq(_controller.module(), address(_module));
    assertEq(_controller.vault(), address(_vault));
    assertEq(_controller.oracle(), address(_oracle));
    assertEq(_controller.feeRecipient(), _FEE_RECIPIENT);
    assertEq(_vault.controller(), address(_controller));
    assertEq(_oracle.configurator(), address(_controller));
    assertEq(_controller.rolesOf(_GOVERNANCE), LibDreamMarginConstants.ROLE_GOVERNANCE);
    assertEq(_controller.rolesOf(_RISK_STEWARD), LibDreamMarginConstants.ROLE_RISK_STEWARD);
    assertEq(_controller.rolesOf(_GUARDIAN), LibDreamMarginConstants.ROLE_GUARDIAN);
    assertEq(_controller.rolesOf(_FEE_COLLECTOR), LibDreamMarginConstants.ROLE_FEE_COLLECTOR);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));
  }

  /// @notice Restricts scheduling to governance and rejects duplicate identifiers.
  function test_onlyGovernanceSchedulesUniqueChanges() external {
    bytes32 changeId = keccak256("change");
    bytes32 payload = keccak256("payload");
    vm.prank(_STRANGER);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.Unauthorized.selector,
        _STRANGER,
        LibDreamMarginConstants.ROLE_GOVERNANCE,
        0
      )
    );
    _controller.scheduleChange(changeId, payload);

    vm.prank(_GOVERNANCE);
    _controller.scheduleChange(changeId, payload);
    vm.prank(_GOVERNANCE);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.ChangeAlreadyScheduled.selector, changeId)
    );
    _controller.scheduleChange(changeId, payload);
  }

  /// @notice Lets the risk steward schedule only generation admission, not generic changes.
  function test_riskStewardHasScopedGenerationSchedulingAuthority() external {
    GenerationConfig memory generation = _generationConfig();
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("steward-generation");
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(changeId, _generationKey, generation, oracleConfig);
    vm.warp(_START + 1 days);
    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
    assertTrue(_controller.getGeneration(_generationKey).enabled);

    vm.prank(_RISK_STEWARD);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.Unauthorized.selector,
        _RISK_STEWARD,
        LibDreamMarginConstants.ROLE_GOVERNANCE,
        LibDreamMarginConstants.ROLE_RISK_STEWARD
      )
    );
    _controller.scheduleChange(keccak256("generic"), keccak256("payload"));
  }

  /// @notice Rejects a zero expiry-compression window before unsafe health math is admitted.
  function test_generationRejectsZeroCompressionWindow() external {
    GenerationConfig memory generation = _generationConfig();
    generation.risk.compressionWindow = 0;
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("zero-compression-window");
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(changeId, _generationKey, generation, oracleConfig);
    vm.warp(_START + 1 days);

    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.ZeroAmount.selector, 0));
    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
  }

  /// @notice Rejects a liquidation incentive above one hundred percent before admission.
  function test_generationRejectsExcessiveLiquidationBonus() external {
    GenerationConfig memory generation = _generationConfig();
    generation.risk.liquidationBonusBps = 10_001;
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("excessive-liquidation-bonus");
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(changeId, _generationKey, generation, oracleConfig);
    vm.warp(_START + 1 days);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.InvalidBps.selector, bytes32("LIQUIDATION_BONUS"), uint256(10_001)
      )
    );
    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
  }

  /// @notice Enforces exact payload commitment and the full governance delay boundary.
  function test_roleChangeRequiresExactMatureCommitment() external {
    bytes32 changeId = keccak256("role-change");
    uint256 roles = LibDreamMarginConstants.ROLE_KEEPER;
    bytes32 payload =
      keccak256(abi.encode(_controller.executeRoleChange.selector, _STRANGER, roles));
    _schedule(changeId, payload);

    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.ChangeNotReady.selector, changeId, _START + 1 days, _START
      )
    );
    _controller.executeRoleChange(changeId, _STRANGER, roles);
    vm.warp(_START + 1 days);
    bytes32 wrongPayload = keccak256(
      abi.encode(
        _controller.executeRoleChange.selector, _STRANGER, LibDreamMarginConstants.ROLE_GUARDIAN
      )
    );
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.ChangePayloadMismatch.selector, payload, wrongPayload
      )
    );
    _controller.executeRoleChange(changeId, _STRANGER, LibDreamMarginConstants.ROLE_GUARDIAN);

    _controller.executeRoleChange(changeId, _STRANGER, roles);
    assertEq(_controller.rolesOf(_STRANGER), roles);
  }

  /// @notice Lets guardian cancel governance changes but not schedule them.
  function test_guardianCanCancelButCannotSchedule() external {
    bytes32 changeId = keccak256("cancel");
    _schedule(changeId, keccak256("payload"));
    vm.prank(_GUARDIAN);
    _controller.cancelChange(changeId);

    vm.prank(_GOVERNANCE);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.ChangeNotScheduled.selector, changeId)
    );
    _controller.cancelChange(changeId);
    vm.prank(_GUARDIAN);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.Unauthorized.selector,
        _GUARDIAN,
        LibDreamMarginConstants.ROLE_GOVERNANCE,
        LibDreamMarginConstants.ROLE_GUARDIAN
      )
    );
    _controller.scheduleChange(changeId, keccak256("other"));
  }

  /// @notice Allows guardian only to make protocol mode monotonically more restrictive.
  function test_guardianEmergencyModesCannotRestoreRisk() external {
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.REDUCE_ONLY);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.REDUCE_ONLY));
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.PAUSED));

    vm.prank(_GUARDIAN);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.UnsafeModeTransition.selector,
        uint8(ProtocolMode.PAUSED),
        uint8(ProtocolMode.ACTIVE)
      )
    );
    _controller.setEmergencyMode(ProtocolMode.ACTIVE);
  }

  /// @notice Restores active mode only through an exact mature governance commitment.
  function test_modeRestorationIsDelayed() external {
    vm.prank(_GUARDIAN);
    _controller.setEmergencyMode(ProtocolMode.PAUSED);
    bytes32 changeId = keccak256("restore");
    bytes32 payload =
      keccak256(abi.encode(_controller.executeModeChange.selector, ProtocolMode.ACTIVE));
    _schedule(changeId, payload);
    vm.warp(_START + 1 days);
    _controller.executeModeChange(changeId, ProtocolMode.ACTIVE);
    assertEq(uint8(_controller.protocolMode()), uint8(ProtocolMode.ACTIVE));
  }

  /// @notice Registers one exact generation and its immutable oracle policy after delay.
  function test_generationRegistrationBindsControllerAndOraclePolicies() external {
    GenerationConfig memory generation = _generationConfig();
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("generation");
    bytes32 payload = keccak256(
      abi.encode(
        _controller.executeGenerationChange.selector, _generationKey, generation, oracleConfig
      )
    );
    _schedule(changeId, payload);
    vm.warp(_START + 1 days);

    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
    GenerationConfig memory stored = _controller.getGeneration(_generationKey);
    assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(generation)));
    (OracleConfig memory storedOracle,) = _oracle.generationState(_generationKey);
    assertEq(keccak256(abi.encode(storedOracle)), keccak256(abi.encode(oracleConfig)));
  }

  /// @notice Lets guardian synchronously disable and freeze only a registered generation.
  function test_guardianFreezesRegisteredGeneration() external {
    _registerGeneration();
    vm.prank(_GUARDIAN);
    _controller.freezeGeneration(_generationKey);
    GenerationConfig memory stored = _controller.getGeneration(_generationKey);
    assertFalse(stored.enabled);
    assertTrue(stored.frozen);

    vm.prank(_GUARDIAN);
    vm.expectRevert(
      abi.encodeWithSelector(LibDreamMarginErrors.UnsupportedGeneration.selector, bytes32("none"))
    );
    _controller.freezeGeneration(bytes32("none"));
  }

  /// @notice Replaces global risk only after validating and consuming the exact commitment.
  function test_globalRiskReplacementIsDelayedAndValidated() external {
    GlobalRiskConfig memory next = _globalRisk();
    next.maxDebtGlobal = 2_000 * _ONE;
    bytes32 changeId = keccak256("global-risk");
    bytes32 payload = keccak256(abi.encode(_controller.executeGlobalRiskChange.selector, next));
    _schedule(changeId, payload);
    vm.warp(_START + 1 days);
    _controller.executeGlobalRiskChange(changeId, next);
    assertEq(_controller.globalRiskConfig().maxDebtGlobal, 2_000 * _ONE);
  }

  /// @notice Rejects generation debt hierarchy above the current global ceiling.
  function test_generationRiskCannotExceedGlobalBounds() external {
    GenerationConfig memory generation = _generationConfig();
    generation.risk.maxDebtPerMarket = 1_001 * _ONE;
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("bad-generation");
    bytes32 payload = keccak256(
      abi.encode(
        _controller.executeGenerationChange.selector, _generationKey, generation, oracleConfig
      )
    );
    _schedule(changeId, payload);
    vm.warp(_START + 1 days);
    vm.expectRevert(
      abi.encodeWithSelector(
        LibDreamMarginErrors.ValueOutOfBounds.selector,
        bytes32("DEBT_HIERARCHY"),
        1_001 * _ONE,
        1_000 * _ONE
      )
    );
    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
  }

  /// @notice Uses position zero and every absent identifier as a nonexistent sentinel.
  function test_absentPositionReverts() external {
    vm.expectRevert(abi.encodeWithSelector(LibDreamMarginErrors.PositionNotFound.selector, 0));
    _controller.getPosition(0);
  }

  /// @notice Returns the initial separated role assignment.
  function _initialRoles() private pure returns (DreamMarginController.InitialRoles memory roles) {
    roles = DreamMarginController.InitialRoles({
      governance: _GOVERNANCE,
      riskSteward: _RISK_STEWARD,
      guardian: _GUARDIAN,
      feeCollector: _FEE_COLLECTOR
    });
  }

  /// @notice Returns global bounds with a one-day governance delay.
  function _globalRisk() private pure returns (GlobalRiskConfig memory config) {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * _ONE,
      maxDailyRealizedLoss: 100 * _ONE,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: 1 days,
      lossWindow: 1 days,
      lossCooldown: 2 days
    });
  }

  /// @notice Returns one valid conservative generation policy.
  function _generationConfig() private view returns (GenerationConfig memory config) {
    config = GenerationConfig({
      key: _key,
      risk: RiskConfig({
        maxDebtPerPosition: 100 * _ONE,
        maxDebtPerOutcome: 200 * _ONE,
        maxDebtPerMarket: 500 * _ONE,
        minDebt: _ONE,
        initialLtvBps: 5_000,
        maintenanceLtvBps: 7_000,
        collateralFactorBps: 8_000,
        liquidationBonusBps: 500,
        maxSpreadBps: 1_000,
        maxSlippageBps: 1_000,
        maxPositionDepthBps: 1_000,
        maxLeverageBps: 20_000,
        openingCutoff: 1_200,
        reduceOnlyCutoff: 600,
        compressionWindow: 3_600,
        maxBookLevels: 4,
        collateralDecimals: 6,
        outcomeIndex: 0
      }),
      marketGroup: keccak256("market-group"),
      enabled: true,
      frozen: false
    });
  }

  /// @notice Returns the exact generation's immutable observation policy.
  function _oracleConfig() private view returns (OracleConfig memory config) {
    config = OracleConfig({
      key: _key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: uint128(3 * _ONE),
      maxObservations: 8,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Schedules one exact payload as governance.
  function _schedule(bytes32 changeId, bytes32 payload) private {
    vm.prank(_GOVERNANCE);
    _controller.scheduleChange(changeId, payload);
  }

  /// @notice Registers the standard generation after its delay.
  function _registerGeneration() private {
    GenerationConfig memory generation = _generationConfig();
    OracleConfig memory oracleConfig = _oracleConfig();
    bytes32 changeId = keccak256("register-helper");
    vm.prank(_RISK_STEWARD);
    _controller.scheduleGenerationChange(changeId, _generationKey, generation, oracleConfig);
    vm.warp(_START + 1 days);
    _controller.executeGenerationChange(changeId, _generationKey, generation, oracleConfig);
  }

  /// @notice Replaces both book sides with valid depth for generation admission.
  function _setBook() private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: 500_000, quantity: 4 * _ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    asks[0] = IDreamDexBinaryPool.BookLevel({price: 600_000, quantity: 4 * _ONE});
    _pool.setBookLevels(true, bids);
    _pool.setBookLevels(false, asks);
  }

  /// @notice Returns the module record bound to the local generation.
  function _moduleMarket() private view returns (MockModuleMarket memory record) {
    record = MockModuleMarket({
      oracleQuestionId: 1,
      outcomeSlotCount: 2,
      voidPolicy: 0,
      collateral: address(_collateral),
      originOperatorId: 0,
      originVenueId: bytes32(0),
      oracleAdapter: address(0xA11),
      creator: address(0xC0DE),
      market: address(_market),
      pool: address(_pool),
      yesId: _YES_ID,
      noId: _NO_ID,
      tradingStart: 900_000,
      expiry: _EXPIRY
    });
  }

  /// @notice Returns the local recyclable pool binding.
  function _poolInfo() private view returns (IDreamDexBinaryPool.BinaryPoolInfo memory info) {
    info = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(_collateral),
      market: address(_market),
      outcomeToken: address(_outcome),
      yesId: _YES_ID,
      noId: _NO_ID,
      oneCollateral: _ONE,
      setBacking: _ONE,
      feeRecipient: address(0xFEE),
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: _SETTLEMENT,
      marketNonce: 1,
      finalized: false
    });
  }

  /// @notice Derives the full generation identity.
  function _deriveKey(MarketKey memory key) private pure returns (bytes32 generationKey) {
    generationKey = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
  }
}

// forge-lint: disable-end(unsafe-typecast, unused-return)
