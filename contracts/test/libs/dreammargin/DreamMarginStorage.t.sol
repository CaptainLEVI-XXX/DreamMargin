// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin namespaced-storage tests
/// @author DreamMargin contributors
/// @notice Verifies slot derivations, namespace isolation, tuple identity, and field persistence.
/// @dev Struct equality is checked by canonical ABI encoding so every declared field participates.

import {
  DREAM_DEX_MARK_ORACLE_STORAGE_SLOT,
  MarkObservation,
  ObservationRing,
  OracleConfig
} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  DREAM_MARGIN_STORAGE_SLOT,
  GenerationConfig,
  GlobalRiskConfig,
  MarketKey,
  PendingChange,
  Position,
  PositionStatus,
  ProtocolMode,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {DREAM_MARGIN_VAULT_STORAGE_SLOT} from "src/libs/dreammargin/LibDreamMarginVaultStorage.sol";

import {DreamMarginStorageHarness} from "test/harness/DreamMarginStorageHarness.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Exercises every field in all three mutable protocol namespaces.
contract DreamMarginStorageTest is Test {
  /// @notice Test harness sharing all three ERC-7201 namespaces at one address.
  DreamMarginStorageHarness private _harness;

  /// @notice Deploys a clean namespaced-storage harness before each test.
  function setUp() external {
    _harness = new DreamMarginStorageHarness();
  }

  /// @notice Proves each literal namespace slot equals the documented ERC-7201 formula.
  function test_namespaceSlotsMatchDerivations() external pure {
    assertEq(DREAM_MARGIN_STORAGE_SLOT, _deriveSlot("dreammargin.storage.Controller"));
    assertEq(DREAM_MARGIN_VAULT_STORAGE_SLOT, _deriveSlot("dreammargin.storage.Vault"));
    assertEq(DREAM_DEX_MARK_ORACLE_STORAGE_SLOT, _deriveSlot("dreammargin.storage.MarkOracle"));
  }

  /// @notice Proves all namespace roots are distinct, aligned, and independently writable.
  function test_namespacesDoNotCollide() external {
    assertTrue(DREAM_MARGIN_STORAGE_SLOT != DREAM_MARGIN_VAULT_STORAGE_SLOT);
    assertTrue(DREAM_MARGIN_STORAGE_SLOT != DREAM_DEX_MARK_ORACLE_STORAGE_SLOT);
    assertTrue(DREAM_MARGIN_VAULT_STORAGE_SLOT != DREAM_DEX_MARK_ORACLE_STORAGE_SLOT);
    assertEq(uint256(DREAM_MARGIN_STORAGE_SLOT) & 0xff, 0);
    assertEq(uint256(DREAM_MARGIN_VAULT_STORAGE_SLOT) & 0xff, 0);
    assertEq(uint256(DREAM_DEX_MARK_ORACLE_STORAGE_SLOT) & 0xff, 0);

    GlobalRiskConfig memory globalRisk = _globalRiskFixture();
    _harness.writeControllerScalars(globalRisk, 11, 12, 13, 14, 15, ProtocolMode.REDUCE_ONLY, true);

    uint256[14] memory vaultValues;
    vaultValues[0] = 101;
    _harness.writeVault(address(0xA1), address(0xB2), vaultValues, 102, true);

    MarketKey memory key = _marketKeyFixture();
    OracleConfig memory oracleConfig = _oracleConfigFixture(key);
    ObservationRing memory ring =
      ObservationRing({nextIndex: 1, cardinality: 2, oldestTimestamp: 3, newestTimestamp: 4});
    MarkObservation memory observation = MarkObservation({
      timestamp: 5,
      poolNonce: 6,
      marketStatus: 1,
      bestBid: 7,
      sameSideDepthBid: 8,
      oppositeSideDepthAsk: 9,
      conservativeMark: 10,
      cumulativeMarkSeconds: 11
    });
    bytes32 generationKey = _harness.deriveGenerationKey(key);
    _harness.writeOracle(generationKey, 0, oracleConfig, ring, observation, true);

    (
      GlobalRiskConfig memory storedGlobalRisk,
      uint256 controllerDebtShares,
      uint256 nextPositionId,
      uint256 realizedLoss,
      uint40 lossWindowStart,
      uint40 reduceOnlyStart,
      ProtocolMode storedMode,
      bool controllerInitialized
    ) = _harness.readControllerScalars();
    (uint256[14] memory storedVaultValues, uint40 vaultAccrual, bool vaultInitialized) =
      _harness.readVault(address(0xA1), address(0xB2));
    (
      OracleConfig memory storedConfig,
      ObservationRing memory storedRing,
      MarkObservation memory storedObservation,
      bool oracleInitialized
    ) = _harness.readOracle(generationKey, 0);

    assertEq(keccak256(abi.encode(storedGlobalRisk)), keccak256(abi.encode(globalRisk)));
    assertEq(controllerDebtShares, 11);
    assertEq(nextPositionId, 12);
    assertEq(realizedLoss, 13);
    assertEq(lossWindowStart, 14);
    assertEq(reduceOnlyStart, 15);
    assertEq(uint8(storedMode), uint8(ProtocolMode.REDUCE_ONLY));
    assertTrue(controllerInitialized);
    assertEq(storedVaultValues[0], 101);
    assertEq(vaultAccrual, 102);
    assertTrue(vaultInitialized);
    assertEq(keccak256(abi.encode(storedConfig)), keccak256(abi.encode(oracleConfig)));
    assertEq(keccak256(abi.encode(storedRing)), keccak256(abi.encode(ring)));
    assertEq(storedObservation.conservativeMark, 10);
    assertTrue(oracleInitialized);
  }

  /// @notice Persists every position field, including each explicitly bounded packed maximum.
  function test_positionFieldsRoundTripAtDeclaredBounds() external {
    Position memory position = Position({
      owner: address(0xA11CE),
      marketId: keccak256("market"),
      pool: address(0xB001),
      outcomeToken: address(0x6909),
      outcomeId: type(uint256).max,
      shares: type(uint128).max,
      debtShares: type(uint128).max,
      initialEquity: type(uint128).max,
      marketNonce: type(uint64).max,
      openedAt: type(uint40).max,
      expiry: type(uint40).max,
      outcomeIndex: type(uint8).max,
      status: PositionStatus.CLOSED
    });

    _harness.writePosition(type(uint256).max, position);

    Position memory stored = _harness.readPosition(type(uint256).max);
    assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(position)));
  }

  /// @notice Persists every generation and risk-configuration field without alternate storage.
  function test_generationFieldsRoundTrip() external {
    MarketKey memory key = _marketKeyFixture();
    GenerationConfig memory config = GenerationConfig({
      key: key,
      risk: _riskFixture(),
      marketGroup: keccak256("market-group"),
      enabled: true,
      frozen: true
    });
    bytes32 generationKey = _harness.deriveGenerationKey(key);

    _harness.writeGeneration(generationKey, config);

    GenerationConfig memory stored = _harness.readGeneration(generationKey);
    assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(config)));
  }

  /// @notice Proves every market-key field contributes to generation identity in canonical order.
  function test_generationKeyBindsEveryTupleField() external view {
    MarketKey memory key = _marketKeyFixture();
    bytes32 expected = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
    assertEq(_harness.deriveGenerationKey(key), expected);

    bytes32 original = expected;
    key.marketId = keccak256("other-market");
    assertTrue(_harness.deriveGenerationKey(key) != original);
    key = _marketKeyFixture();
    key.pool = address(0xCAFE);
    assertTrue(_harness.deriveGenerationKey(key) != original);
    key = _marketKeyFixture();
    key.marketNonce++;
    assertTrue(_harness.deriveGenerationKey(key) != original);
    key = _marketKeyFixture();
    key.outcomeToken = address(0xBEEF);
    assertTrue(_harness.deriveGenerationKey(key) != original);
    key = _marketKeyFixture();
    key.outcomeId++;
    assertTrue(_harness.deriveGenerationKey(key) != original);
    key = _marketKeyFixture();
    key.collateral = address(0xC011A7);
    assertTrue(_harness.deriveGenerationKey(key) != original);
  }

  /// @notice Persists every controller scalar and independent mapping category.
  function test_controllerStateFieldsRoundTrip() external {
    GlobalRiskConfig memory globalRisk = _globalRiskFixture();
    _harness.writeControllerScalars(
      globalRisk,
      type(uint256).max - 1,
      type(uint256).max,
      33,
      type(uint40).max - 1,
      type(uint40).max,
      ProtocolMode.PAUSED,
      true
    );

    (
      GlobalRiskConfig memory storedRisk,
      uint256 totalDebtShares,
      uint256 nextPositionId,
      uint256 dailyRealizedLoss,
      uint40 lossWindowStartedAt,
      uint40 reduceOnlyTriggeredAt,
      ProtocolMode mode,
      bool initialized
    ) = _harness.readControllerScalars();

    assertEq(keccak256(abi.encode(storedRisk)), keccak256(abi.encode(globalRisk)));
    assertEq(totalDebtShares, type(uint256).max - 1);
    assertEq(nextPositionId, type(uint256).max);
    assertEq(dailyRealizedLoss, 33);
    assertEq(lossWindowStartedAt, type(uint40).max - 1);
    assertEq(reduceOnlyTriggeredAt, type(uint40).max);
    assertEq(uint8(mode), uint8(ProtocolMode.PAUSED));
    assertTrue(initialized);

    uint256[5] memory values = [uint256(41), 42, 43, 44, 45];
    PendingChange memory change_ =
      PendingChange({payloadHash: keccak256("payload"), executableAt: 46, proposer: address(0x47)});
    bytes32 generationKey = keccak256("generation");
    bytes32 marketGroup = keccak256("group");
    bytes32 changeId = keccak256("change");
    _harness.writeControllerMappings(
      address(0x6909), 48, generationKey, marketGroup, address(0x49), changeId, 50, values, change_
    );

    (uint256[5] memory storedValues, PendingChange memory storedChange, bool recognized) = _harness.readControllerMappings(
      address(0x6909), 48, generationKey, marketGroup, address(0x49), changeId, 50
    );
    assertEq(keccak256(abi.encode(storedValues)), keccak256(abi.encode(values)));
    assertEq(keccak256(abi.encode(storedChange)), keccak256(abi.encode(change_)));
    assertTrue(recognized);
  }

  /// @notice Persists every vault mapping and accounting scalar through its namespace.
  function test_vaultStateFieldsRoundTrip() external {
    uint256[14] memory values;
    for (uint256 i = 0; i < values.length; ++i) {
      values[i] = i + 1;
    }

    _harness.writeVault(address(0xA55E7), address(0x5EED), values, type(uint40).max, true);

    (uint256[14] memory storedValues, uint40 lastAccrual, bool initialized) =
      _harness.readVault(address(0xA55E7), address(0x5EED));
    assertEq(keccak256(abi.encode(storedValues)), keccak256(abi.encode(values)));
    assertEq(lastAccrual, type(uint40).max);
    assertTrue(initialized);
  }

  /// @notice Persists every oracle configuration, ring, and observation field.
  function test_oracleStateFieldsRoundTripAtDeclaredBounds() external {
    MarketKey memory key = _marketKeyFixture();
    OracleConfig memory config = _oracleConfigFixture(key);
    ObservationRing memory ring = ObservationRing({
      nextIndex: type(uint16).max,
      cardinality: type(uint16).max,
      oldestTimestamp: type(uint40).max - 1,
      newestTimestamp: type(uint40).max
    });
    MarkObservation memory observation = MarkObservation({
      timestamp: type(uint40).max,
      poolNonce: type(uint64).max,
      marketStatus: type(uint8).max,
      bestBid: type(uint128).max,
      sameSideDepthBid: type(uint128).max - 1,
      oppositeSideDepthAsk: type(uint128).max - 2,
      conservativeMark: type(uint128).max - 3,
      cumulativeMarkSeconds: type(uint256).max
    });
    bytes32 generationKey = _harness.deriveGenerationKey(key);

    _harness.writeOracle(generationKey, type(uint16).max, config, ring, observation, true);

    (
      OracleConfig memory storedConfig,
      ObservationRing memory storedRing,
      MarkObservation memory storedObservation,
      bool initialized
    ) = _harness.readOracle(generationKey, type(uint16).max);
    assertEq(keccak256(abi.encode(storedConfig)), keccak256(abi.encode(config)));
    assertEq(keccak256(abi.encode(storedRing)), keccak256(abi.encode(ring)));
    assertEq(keccak256(abi.encode(storedObservation)), keccak256(abi.encode(observation)));
    assertTrue(initialized);
  }

  /// @notice Derives an ERC-7201 namespace root from its label.
  /// @param namespace Human-readable namespace label.
  /// @return slot Aligned namespace storage root.
  function _deriveSlot(string memory namespace) private pure returns (bytes32 slot) {
    slot = bytes32(
      uint256(keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1))) & ~uint256(0xff)
    );
  }

  /// @notice Returns a complete deterministic market-generation tuple.
  /// @return key Market-generation fixture.
  function _marketKeyFixture() private pure returns (MarketKey memory key) {
    key = MarketKey({
      marketId: keccak256("market"),
      pool: address(0xB001),
      marketNonce: 7,
      outcomeToken: address(0x6909),
      outcomeId: 9,
      collateral: address(0xC011A)
    });
  }

  /// @notice Returns a configuration with every risk field nonzero and distinct.
  /// @return risk Risk fixture.
  function _riskFixture() private pure returns (RiskConfig memory risk) {
    risk = RiskConfig({
      maxDebtPerPosition: 1,
      maxDebtPerOutcome: 2,
      maxDebtPerMarket: 3,
      minDebt: 4,
      initialLtvBps: 5,
      maintenanceLtvBps: 6,
      collateralFactorBps: 7,
      liquidationBonusBps: 8,
      maxSpreadBps: 9,
      maxSlippageBps: 10,
      maxPositionDepthBps: 11,
      maxLeverageBps: 12,
      openingCutoff: 13,
      reduceOnlyCutoff: 14,
      compressionWindow: 15,
      maxBookLevels: 16,
      collateralDecimals: 17,
      outcomeIndex: 1
    });
  }

  /// @notice Returns a configuration with every global risk field nonzero and distinct.
  /// @return risk Global-risk fixture.
  function _globalRiskFixture() private pure returns (GlobalRiskConfig memory risk) {
    risk = GlobalRiskConfig({
      maxDebtGlobal: 21,
      maxDailyRealizedLoss: 22,
      maxVaultUtilizationBps: 23,
      governanceDelay: 24,
      lossWindow: 25,
      lossCooldown: 26
    });
  }

  /// @notice Returns a configuration with every oracle policy field nonzero and distinct.
  /// @param key Exact market-generation tuple.
  /// @return config Oracle configuration fixture.
  function _oracleConfigFixture(MarketKey memory key)
    private
    pure
    returns (OracleConfig memory config)
  {
    config = OracleConfig({
      key: key,
      minAge: 31,
      updateInterval: 32,
      staleAfter: 33,
      depthQuantity: 34,
      maxObservations: 35,
      maxBookLevels: 36,
      enabled: true
    });
  }
}
