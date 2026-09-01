// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin whole-system invariant handler
/// @author DreamMargin contributors
/// @notice Drives bounded vault, trading, liquidation, settlement, and integration transitions.
/// @dev One active lane remains mutable while a second lane supplies terminal-loss coverage.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {PositionClose} from "src/dreammargin/base/PositionClose.sol";
import {PositionLiquidation} from "src/dreammargin/base/PositionLiquidation.sol";
import {PositionOpen} from "src/dreammargin/base/PositionOpen.sol";
import {PositionSettlement} from "src/dreammargin/base/PositionSettlement.sol";
import {IDreamDexMarkOracle} from "src/interfaces/dreammargin/IDreamDexMarkOracle.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IDreamDexBinarySettlement} from "src/interfaces/integrations/IDreamDexBinarySettlement.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";
import {
  GenerationConfig,
  GlobalRiskConfig,
  MarketKey,
  Position,
  PositionStatus,
  ProtocolMode,
  RiskConfig
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {LibPositionRisk, PositionHealth} from "src/libs/dreammargin/LibPositionRisk.sol";
import {DreamDexMarkOracle} from "src/oracle/DreamDexMarkOracle.sol";
import {DreamMarginVault} from "src/vault/DreamMarginVault.sol";

import {DreamMarginControllerHarness} from "test/harness/DreamMarginControllerHarness.sol";
import {MockCallbackERC20} from "test/mock/AdversarialERC20.sol";
import {MockDreamDexBinaryMarket} from "test/mock/MockDreamDexBinaryMarket.sol";
import {MockDreamDexBinaryModule, MockModuleMarket} from "test/mock/MockDreamDexBinaryModule.sol";
import {MockDreamDexBinaryPool} from "test/mock/MockDreamDexBinaryPool.sol";
import {MockDreamDexBinarySettlement} from "test/mock/MockDreamDexBinarySettlement.sol";
import {MockERC6909} from "test/mock/MockERC6909.sol";

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

// Bounded timestamp manipulation and fixed-width fixture construction are intentional here.
// The handler intentionally performs external state-machine calls, compares exact balance deltas,
// advances consensus time, and enumerates its bounded position registry.
// forge-lint: disable-start(unsafe-cheatcode, unsafe-typecast, unused-return, reentrancy-no-eth, incorrect-strict-equality, block-timestamp, calls-loop)

/// @notice Stateful action surface targeted by the whole-system invariant engine.
contract DreamMarginSystemHandler is Test {
  /// @notice One whole six-decimal collateral or outcome token.
  uint256 public constant ONE = 1e6;

  /// @notice Trading expiry kept far beyond every bounded invariant sequence.
  uint64 public constant EXPIRY = 40_000_000;

  /// @notice Governance delay used by the fixture.
  uint40 public constant GOVERNANCE_DELAY = 1 days;

  /// @notice Unprivileged account used for negative authorization checks.
  address public constant STRANGER = address(0xBADD1E);

  uint128 private constant _DEPTH_QUANTITY = 100_000_000;
  uint256 private constant _START = 1_000_000;
  uint256 private constant _STABLE_BID = 500_000;
  uint256 private constant _INITIAL_SHARES = 20 * ONE;
  uint256 private constant _OPEN_DEBT = 10 * ONE;

  /// @notice Shared six-decimal collateral.
  MockCallbackERC20 public immutable collateral;

  /// @notice Shared exact-ID outcome token.
  MockERC6909 public immutable outcome;

  /// @notice Permanent settlement singleton.
  MockDreamDexBinarySettlement public immutable settlement;

  /// @notice DreamDEX market registry model.
  MockDreamDexBinaryModule public immutable module;

  /// @notice Collateral vault under test.
  DreamMarginVault public immutable vault;

  /// @notice Conservative mark oracle under test.
  DreamDexMarkOracle public immutable oracle;

  /// @notice Complete lifecycle controller under test.
  DreamMarginControllerHarness public immutable controller;

  /// @notice Active DreamDEX market model.
  MockDreamDexBinaryMarket public immutable activeMarket;

  /// @notice Active DreamDEX pool model.
  MockDreamDexBinaryPool public immutable activePool;

  /// @notice Terminal DreamDEX market model.
  MockDreamDexBinaryMarket public immutable terminalMarket;

  /// @notice Terminal DreamDEX pool model.
  MockDreamDexBinaryPool public immutable terminalPool;

  /// @notice Exact active-generation key.
  bytes32 public immutable activeGenerationKey;

  /// @notice Exact terminal-generation key.
  bytes32 public immutable terminalGenerationKey;

  /// @notice Active market debt bucket.
  bytes32 public immutable activeMarketGroup;

  /// @notice Terminal market debt bucket.
  bytes32 public immutable terminalMarketGroup;

  /// @notice Active YES outcome ID.
  uint256 public immutable activeOutcomeId;

  /// @notice Terminal YES outcome ID.
  uint256 public immutable terminalOutcomeId;

  /// @notice Whether deterministic critical-path seeding finished.
  bool public initialized;

  /// @notice Number of successful risk-increasing opens.
  uint256 public successfulOpens;

  /// @notice Number of successful debt reductions.
  uint256 public successfulRepayments;

  /// @notice Number of successful permissionless liquidations.
  uint256 public successfulLiquidations;

  /// @notice Number of successful terminal settlements.
  uint256 public successfulSettlements;

  /// @notice Number of rejected recycled-generation actions.
  uint256 public recycledGenerationRejections;

  /// @notice Number of rejected unauthorized lifecycle actions.
  uint256 public unauthorizedRejections;

  /// @notice Number of completed pause-safety rehearsals.
  uint256 public pauseSafetyProofs;

  /// @notice Sticky violation flag for post-open risk checks.
  bool public riskIncreaseViolation;

  /// @notice Sticky violation flag for liquidation eligibility.
  bool public liquidationEligibilityViolation;

  /// @notice Sticky violation flag for generation recycling.
  bool public generationBindingViolation;

  /// @notice Sticky violation flag for authorization boundaries.
  bool public authorizationViolation;

  /// @notice Sticky violation flag for paused-mode behavior.
  bool public pauseSafetyViolation;

  /// @notice Sticky violation flag for debt-first terminal allocation.
  bool public debtFirstViolation;

  /// @notice Sticky violation flag for execution parameter bounds.
  bool public executionBoundsViolation;

  /// @notice Sticky violation flag for rounding checks.
  bool public roundingViolation;

  /// @notice Every position identifier ever created by this handler.
  uint256[] public positionIds;

  /// @notice Immutable identity digest captured when each position opens.
  mapping(uint256 positionId => bytes32 digest) public positionIdentity;

  MarketKey private _activeKey;
  MarketKey private _terminalKey;
  uint256 private _activeBid = _STABLE_BID;

  /// @notice Deploys two exact generations and one complete DreamMargin stack.
  constructor() {
    vm.warp(_START);
    collateral = new MockCallbackERC20();
    outcome = new MockERC6909();
    settlement = new MockDreamDexBinarySettlement(address(outcome));

    activeMarketGroup = keccak256("invariant-active-group");
    terminalMarketGroup = keccak256("invariant-terminal-group");
    bytes32 activeMarketId = keccak256("invariant-active-market");
    bytes32 terminalMarketId = keccak256("invariant-terminal-market");

    (
      MockDreamDexBinaryMarket activeMarket_,
      MockDreamDexBinaryPool activePool_,
      MarketKey memory a
    ) = _deployLane(activeMarketId);
    (
      MockDreamDexBinaryMarket terminalMarket_,
      MockDreamDexBinaryPool terminalPool_,
      MarketKey memory t
    ) = _deployLane(terminalMarketId);
    activeMarket = activeMarket_;
    activePool = activePool_;
    terminalMarket = terminalMarket_;
    terminalPool = terminalPool_;
    _activeKey = a;
    _terminalKey = t;
    activeOutcomeId = a.outcomeId;
    terminalOutcomeId = t.outcomeId;
    activeGenerationKey = _deriveKey(a);
    terminalGenerationKey = _deriveKey(t);

    module = new MockDreamDexBinaryModule(address(settlement));
    module.setMarket(
      activeMarketId, 1, _moduleMarket(a, address(activeMarket_), address(activePool_))
    );
    module.setMarket(
      terminalMarketId, 1, _moduleMarket(t, address(terminalMarket_), address(terminalPool_))
    );
    _setBook(activePool_, _STABLE_BID);
    _setBook(terminalPool_, _STABLE_BID);

    PositionOpen positionOpen = new PositionOpen();
    PositionClose positionClose = new PositionClose();
    PositionLiquidation positionLiquidation = new PositionLiquidation();
    PositionSettlement positionSettlement = new PositionSettlement();
    uint256 nextNonce = vm.getNonce(address(this));
    address predictedController = vm.computeCreateAddress(address(this), nextNonce + 2);
    vault = new DreamMarginVault(address(collateral), predictedController, 0.05e18);
    oracle = new DreamDexMarkOracle(address(module), predictedController);
    DreamMarginController.InitialRoles memory roles = DreamMarginController.InitialRoles({
      governance: address(this),
      riskSteward: address(this),
      guardian: address(this),
      feeCollector: address(this)
    });
    controller = new DreamMarginControllerHarness(
      address(module),
      address(vault),
      address(oracle),
      address(0xFEE),
      address(positionOpen),
      address(positionClose),
      address(positionLiquidation),
      address(positionSettlement),
      roles,
      _globalRisk()
    );
    assertEq(address(controller), predictedController);
  }

  /// @notice Funds, registers, matures, and seeds every critical lifecycle path once.
  function initialize() external {
    require(!initialized, "ALREADY_INITIALIZED");
    initialized = true;
    _fundAndApprove();
    _registerGeneration(activeGenerationKey, _activeKey, activeMarketGroup, "REGISTER_ACTIVE");
    _registerGeneration(
      terminalGenerationKey, _terminalKey, terminalMarketGroup, "REGISTER_TERMINAL"
    );
    vm.warp(block.timestamp + GOVERNANCE_DELAY);
    _executeRegistration(activeGenerationKey, _activeKey, activeMarketGroup, "REGISTER_ACTIVE");
    _executeRegistration(
      terminalGenerationKey, _terminalKey, terminalMarketGroup, "REGISTER_TERMINAL"
    );
    oracle.observe(activeGenerationKey);
    oracle.observe(terminalGenerationKey);
    vm.warp(block.timestamp + 60);
    oracle.observe(activeGenerationKey);
    oracle.observe(terminalGenerationKey);

    uint256 first = _open(_activeKey, activeGenerationKey);
    controller.repay(first, 2 * ONE);
    ++successfulRepayments;
    controller.addCollateral(first, ONE);

    uint256 liquidated = _open(_activeKey, activeGenerationKey);
    _setActiveBook(400_000);
    vm.warp(block.timestamp + 30);
    oracle.observe(activeGenerationKey);
    controller.liquidate(_take(liquidated, 7 * ONE));
    ++successfulLiquidations;
    _setActiveBook(_STABLE_BID);
    vm.warp(block.timestamp + 30);
    oracle.observe(activeGenerationKey);

    uint256 terminal = _open(_terminalKey, terminalGenerationKey);
    _finalizeTerminalAsLoser();
    uint256 ownerBefore = collateral.balanceOf(address(this));
    (uint256 repaid, uint256 ownerAssets,) = controller.settle(terminal);
    if (ownerAssets != 0 || collateral.balanceOf(address(this)) != ownerBefore - repaid) {
      debtFirstViolation = true;
    }
    ++successfulSettlements;
    controller.recordRecovery(ONE);

    _provePauseSafety(first);
    _proveUnauthorized(first);
  }

  /// @notice Opens a standard bounded 2x position when current state permits it.
  /// @param seed Fuzz seed retained for selector diversity.
  function actOpen(uint256 seed) external {
    seed;
    if (controller.protocolMode() != ProtocolMode.ACTIVE) return;
    try controller.openPosition(_openParams(_activeKey)) returns (
      uint256 positionId, uint256, uint256
    ) {
      _track(positionId, activeGenerationKey);
      ++successfulOpens;
      _checkRiskIncrease(positionId);
    } catch {}
  }

  /// @notice Repays debt, adds exact collateral, or attempts a health-checked withdrawal.
  /// @param seed Selects a live position, operation, and bounded amount.
  function actManage(uint256 seed) external {
    uint256 positionId = _activePositionId(seed);
    if (positionId == 0) return;
    Position memory position = controller.getPosition(positionId);
    uint256 operation = seed % 3;
    if (operation == 0 && position.debtShares != 0) {
      uint256 debt = vault.debtAssets(position.debtShares);
      uint256 assets = seed % debt + 1;
      collateral.mint(address(this), assets);
      try controller.repay(positionId, assets) returns (uint256 repaid) {
        if (repaid > assets) roundingViolation = true;
        ++successfulRepayments;
      } catch {}
    } else if (operation == 1) {
      uint256 shares = seed % (5 * ONE) + 1;
      outcome.mint(address(this), position.outcomeId, shares);
      try controller.addCollateral(positionId, shares) {} catch {}
    } else if (position.shares != 0) {
      uint256 shares = seed % uint256(position.shares) + 1;
      try controller.withdrawCollateral(positionId, shares) {} catch {}
    }
  }

  /// @notice Attempts a bounded sale reduction or complete close on a live position.
  /// @param seed Selects the position, route, quantity, and close mode.
  function actExit(uint256 seed) external {
    uint256 positionId = _activePositionId(seed);
    if (positionId == 0) return;
    Position memory position = controller.getPosition(positionId);
    if (seed & 1 == 0) {
      uint256 lots = uint256(position.shares) / ONE;
      if (lots == 0) return;
      uint256 quantity = (seed % lots + 1) * ONE;
      IDreamMarginController.DeleverageParams memory params = IDreamMarginController.DeleverageParams({
        positionId: positionId,
        sharesToSell: quantity,
        minCollateralOut: 0,
        limitPrice: _activeBid,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600
      });
      try controller.deleverage(params) returns (uint256 repaid, uint256) {
        if (repaid != 0) ++successfulRepayments;
        _checkLastExecution(activePool);
      } catch {}
    } else {
      IDreamMarginController.CloseParams memory params = IDreamMarginController.CloseParams({
        positionId: positionId,
        maxRepayAssets: type(uint256).max,
        minCollateralOut: 0,
        limitPrice: _activeBid,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600,
        withdrawOutcome: seed & 2 != 0
      });
      try controller.close(params) returns (uint256 repaid, uint256 ownerAssets) {
        ownerAssets;
        if (repaid != 0) ++successfulRepayments;
        if (!params.withdrawOutcome) _checkLastExecution(activePool);
      } catch {}
    }
  }

  /// @notice Mutates and records one fresh bounded active-generation book sample.
  /// @param seed Selects a forty-, forty-five-, or fifty-cent executable bid.
  function actMark(uint256 seed) external {
    uint256 choice = seed % 3;
    uint256 bid = choice == 0 ? 400_000 : choice == 1 ? 450_000 : _STABLE_BID;
    _setActiveBook(bid);
    vm.warp(block.timestamp + 30);
    try oracle.observe(activeGenerationKey) {} catch {}
  }

  /// @notice Attempts either permissionless liquidation route against a live position.
  /// @param seed Selects position and route.
  function actLiquidate(uint256 seed) external {
    uint256 positionId = _activePositionId(seed);
    if (positionId == 0) return;
    bool wasEligible = _isSimplyLiquidatable(positionId);
    IDreamMarginController.LiquidationParams memory params;
    if (seed & 1 == 0) {
      params = _take(positionId, type(uint256).max);
    } else {
      params = IDreamMarginController.LiquidationParams({
        positionId: positionId,
        maxDebtAssets: type(uint256).max,
        minSharesOut: 0,
        minCollateralOut: 0,
        limitPrice: _activeBid,
        orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
        deadline: block.timestamp + 600,
        route: IDreamMarginController.LiquidationRoute.DIRECT_SALE
      });
    }
    try controller.liquidate(params) returns (uint256 repaid, uint256, uint256) {
      if (!wasEligible) liquidationEligibilityViolation = true;
      if (repaid != 0) ++successfulRepayments;
      ++successfulLiquidations;
      if (params.route == IDreamMarginController.LiquidationRoute.DIRECT_SALE) {
        _checkLastExecution(activePool);
      }
    } catch {}
  }

  /// @notice Deposits fresh liquidity or redeems a bounded immediately liquid amount.
  /// @param seed Selects direction and bounded quantity.
  function actVault(uint256 seed) external {
    if (seed & 1 == 0) {
      uint256 assets = seed % (25 * ONE) + 1;
      collateral.mint(address(this), assets);
      if (vault.previewDeposit(assets) == 0) return;
      vault.deposit(assets, address(this));
    } else {
      uint256 maximum = vault.maxRedeem(address(this));
      if (maximum == 0) return;
      uint256 shares = seed % maximum + 1;
      vault.redeem(shares, address(this), address(this));
    }
  }

  /// @notice Supplies a bounded recovery without recreating a written-off receivable.
  /// @param seed Chooses an amount no larger than unrecovered realized loss.
  function actRecovery(uint256 seed) external {
    uint256 realized = vault.realizedBadDebt();
    uint256 recovered = vault.recoveredBadDebt();
    if (realized <= recovered) return;
    uint256 assets = seed % (realized - recovered) + 1;
    collateral.mint(address(this), assets);
    try controller.recordRecovery(assets) {} catch {}
  }

  /// @notice Temporarily recycles the active pool and proves the pinned generation rejects use.
  /// @param seed Fuzz seed retained for selector diversity.
  function actRecycle(uint256 seed) external {
    seed;
    IDreamDexBinaryPool.BinaryPoolInfo memory original = activePool.getBinaryPoolParams();
    IDreamDexBinaryPool.BinaryPoolInfo memory recycled = original;
    recycled.marketNonce = original.marketNonce + 1;
    activePool.recycle(recycled, activePool.marketExpiryNs());
    try controller.openPosition(_openParams(_activeKey)) returns (
      uint256 positionId, uint256, uint256
    ) {
      generationBindingViolation = true;
      _track(positionId, activeGenerationKey);
    } catch {
      ++recycledGenerationRejections;
    }
    activePool.recycle(original, activePool.marketExpiryNs());
  }

  /// @notice Attempts an owner-only reduction from an unrelated account.
  /// @param seed Selects a live position.
  function actUnauthorized(uint256 seed) external {
    uint256 positionId = _activePositionId(seed);
    if (positionId == 0) return;
    vm.prank(STRANGER);
    try controller.repay(positionId, ONE) returns (uint256) {
      authorizationViolation = true;
    } catch {
      ++unauthorizedRejections;
    }
  }

  /// @notice Returns the number of tracked positions.
  /// @return count Number of positions created during setup and invariant actions.
  function positionCount() external view returns (uint256 count) {
    count = positionIds.length;
  }

  /// @notice Returns the full active generation tuple.
  /// @return key Exact active market key.
  function activeKey() external view returns (MarketKey memory key) {
    key = _activeKey;
  }

  /// @notice Returns the full terminal generation tuple.
  /// @return key Exact terminal market key.
  function terminalKey() external view returns (MarketKey memory key) {
    key = _terminalKey;
  }

  /// @notice Seeds one standard open and records its immutable identity.
  function _open(MarketKey memory key, bytes32 generationKey) private returns (uint256 positionId) {
    (positionId,,) = controller.openPosition(_openParams(key));
    _track(positionId, generationKey);
    ++successfulOpens;
    _checkRiskIncrease(positionId);
  }

  /// @notice Captures one position's immutable tuple after successful creation.
  function _track(uint256 positionId, bytes32 generationKey) private {
    Position memory position = controller.getPosition(positionId);
    positionIds.push(positionId);
    positionIdentity[positionId] = _identity(position);
    if (_derivePositionKey(position) != generationKey) generationBindingViolation = true;
  }

  /// @notice Independently checks core post-open health, depth, and cap boundaries.
  function _checkRiskIncrease(uint256 positionId) private {
    Position memory position = controller.getPosition(positionId);
    bytes32 generationKey = _derivePositionKey(position);
    GenerationConfig memory config = controller.getGeneration(generationKey);
    (uint256 mark,,) = oracle.conservativeTwap(generationKey);
    uint256 gross = LibPositionRisk.collateralValueDown(position.shares, mark, ONE);
    uint256 debt = vault.debtAssets(position.debtShares);
    PositionHealth memory health = LibPositionRisk.positionHealth(gross, debt);
    (OracleConfig memory oracleConfig,) = oracle.generationState(generationKey);
    uint256 maximumShares = FixedPointMathLib.fullMulDiv(
      oracleConfig.depthQuantity, config.risk.maxPositionDepthBps, LibDreamMarginConstants.BPS
    );
    (,, uint256 marketDebtShares, uint256 globalDebtShares) = controller.aggregateState(
      generationKey, config.marketGroup, position.outcomeToken, position.outcomeId
    );
    if (
      health.ltvBps > config.risk.initialLtvBps || position.shares > maximumShares
        || debt > config.risk.maxDebtPerPosition
        || vault.debtAssets(marketDebtShares) > config.risk.maxDebtPerMarket
        || vault.debtAssets(globalDebtShares) > controller.globalRiskConfig().maxDebtGlobal
    ) riskIncreaseViolation = true;
  }

  /// @notice Computes a deliberately independent lower-bound liquidation predicate.
  function _isSimplyLiquidatable(uint256 positionId) private view returns (bool eligible) {
    Position memory position = controller.getPosition(positionId);
    bytes32 generationKey = _derivePositionKey(position);
    GenerationConfig memory config = controller.getGeneration(generationKey);
    try IDreamDexMarkOracle(address(oracle)).conservativeTwap(generationKey) returns (
      uint256 mark, uint256, uint256
    ) {
      uint256 haircut = FixedPointMathLib.fullMulDiv(
        mark, config.risk.collateralFactorBps, LibDreamMarginConstants.BPS
      );
      uint256 gross = LibPositionRisk.collateralValueDown(position.shares, haircut, ONE);
      PositionHealth memory health =
        LibPositionRisk.positionHealth(gross, vault.debtAssets(position.debtShares));
      uint256 timeToExpiry =
        position.expiry > block.timestamp ? uint256(position.expiry) - block.timestamp : 0;
      uint256 maintenance = LibPositionRisk.maintenanceLtvBps(
        config.risk.maintenanceLtvBps, timeToExpiry, config.risk.compressionWindow
      );
      eligible = maintenance == 0 || health.ltvBps > maintenance;
    } catch {
      eligible = false;
    }
  }

  /// @notice Proves PAUSED rejects opening while owner reductions remain available.
  function _provePauseSafety(uint256 positionId) private {
    controller.setEmergencyMode(ProtocolMode.PAUSED);
    try controller.openPosition(_openParams(_activeKey)) returns (uint256 id, uint256, uint256) {
      pauseSafetyViolation = true;
      _track(id, activeGenerationKey);
    } catch {}
    try controller.repay(positionId, ONE) returns (uint256) {
      ++successfulRepayments;
    } catch {
      pauseSafetyViolation = true;
    }
    outcome.mint(address(this), activeOutcomeId, ONE);
    try controller.addCollateral(positionId, ONE) {}
    catch {
      pauseSafetyViolation = true;
    }
    ++pauseSafetyProofs;
  }

  /// @notice Proves an unrelated account cannot mutate an owner's position.
  function _proveUnauthorized(uint256 positionId) private {
    vm.prank(STRANGER);
    try controller.repay(positionId, ONE) returns (uint256) {
      authorizationViolation = true;
    } catch {
      ++unauthorizedRejections;
    }
  }

  /// @notice Verifies every accepted venue write used the immediate bounded adapter shape.
  function _checkLastExecution(MockDreamDexBinaryPool pool) private {
    if (
      pool.lastKind() > 3 || pool.lastPrice() == 0 || pool.lastPrice() >= ONE
        || pool.lastPrice() % 10_000 != 0 || pool.lastQuantity() < ONE
        || pool.lastQuantity() % ONE != 0
        || (pool.lastOrderType() != LibDreamMarginConstants.ORDER_TYPE_FOK
          && pool.lastOrderType() != LibDreamMarginConstants.ORDER_TYPE_IOC)
        || pool.lastSelfMatchingOption() != 0 || pool.lastBuilder() != address(0)
        || pool.lastBuilderFeeBpsTimes1k() != 0
        || pool.lastDeadlineNs() <= pool.lastSubmittedAt() * 1e9
        || pool.lastDeadlineNs() > pool.marketExpiryNs()
    ) {
      executionBoundsViolation = true;
    }
  }

  /// @notice Returns a tracked active position, or zero when none remains.
  function _activePositionId(uint256 seed) private view returns (uint256 positionId) {
    uint256 length = positionIds.length;
    if (length == 0) return 0;
    uint256 start = seed % length;
    for (uint256 i = 0; i < length; ++i) {
      positionId = positionIds[(start + i) % length];
      Position memory position = controller.getPosition(positionId);
      if (
        position.status == PositionStatus.ACTIVE
          && _derivePositionKey(position) == activeGenerationKey
      ) return positionId;
    }
    positionId = 0;
  }

  /// @notice Deploys one encoded market and its predicted recyclable pool.
  function _deployLane(bytes32 marketId)
    private
    returns (MockDreamDexBinaryMarket market, MockDreamDexBinaryPool pool, MarketKey memory key)
  {
    uint256 nextNonce = vm.getNonce(address(this));
    address predictedPool = vm.computeCreateAddress(address(this), nextNonce + 1);
    uint256 yesId = _outcomeId(predictedPool, 1, 0);
    uint256 noId = _outcomeId(predictedPool, 1, 1);
    market = new MockDreamDexBinaryMarket(
      address(outcome), yesId, noId, predictedPool, address(collateral), EXPIRY
    );
    IDreamDexBinaryPool.OrderBookParameters memory grid =
      IDreamDexBinaryPool.OrderBookParameters({tickSize: 10_000, minQuantity: ONE, lotSize: ONE});
    IDreamDexBinaryPool.BinaryPoolInfo memory info = IDreamDexBinaryPool.BinaryPoolInfo({
      collateralToken: address(collateral),
      market: address(market),
      outcomeToken: address(outcome),
      yesId: yesId,
      noId: noId,
      oneCollateral: ONE,
      setBacking: ONE,
      feeRecipient: address(0xFEE),
      makerFeeBpsTimes1k: 0,
      takerFeeBpsTimes1k: 0,
      maxBuilderFeeBpsTimes1k: 0,
      settlementFeeBpsTimes1k: 0,
      settlement: address(settlement),
      marketNonce: 1,
      finalized: false
    });
    pool = new MockDreamDexBinaryPool(info, grid, EXPIRY * 1e9);
    assertEq(address(pool), predictedPool);
    key = MarketKey({
      marketId: marketId,
      pool: address(pool),
      marketNonce: 1,
      outcomeToken: address(outcome),
      outcomeId: yesId,
      collateral: address(collateral)
    });
  }

  /// @notice Funds all actors and grants only exact-ID outcome allowances.
  function _fundAndApprove() private {
    collateral.mint(address(this), 20_000 * ONE);
    collateral.mint(address(activePool), 5_000 * ONE);
    collateral.mint(address(terminalPool), 5_000 * ONE);
    collateral.mint(address(settlement), 5_000 * ONE);
    outcome.mint(address(this), activeOutcomeId, 10_000 * ONE);
    outcome.mint(address(this), terminalOutcomeId, 10_000 * ONE);
    outcome.mint(address(activePool), activeOutcomeId, 5_000 * ONE);
    outcome.mint(address(terminalPool), terminalOutcomeId, 5_000 * ONE);
    collateral.approve(address(vault), type(uint256).max);
    collateral.approve(address(controller), type(uint256).max);
    outcome.approve(address(controller), activeOutcomeId, type(uint256).max);
    outcome.approve(address(controller), terminalOutcomeId, type(uint256).max);
    vault.deposit(2_000 * ONE, address(this));
  }

  /// @notice Schedules one exact generation registration.
  function _registerGeneration(
    bytes32 generationKey,
    MarketKey memory key,
    bytes32 marketGroup,
    string memory salt
  ) private {
    GenerationConfig memory generation = _generation(key, marketGroup);
    OracleConfig memory oracleConfig = _oraclePolicy(key);
    controller.scheduleGenerationChange(
      keccak256(abi.encode(salt)), generationKey, generation, oracleConfig
    );
  }

  /// @notice Executes one mature exact generation registration.
  function _executeRegistration(
    bytes32 generationKey,
    MarketKey memory key,
    bytes32 marketGroup,
    string memory salt
  ) private {
    controller.executeGenerationChange(
      keccak256(abi.encode(salt)), generationKey, _generation(key, marketGroup), _oraclePolicy(key)
    );
  }

  /// @notice Resolves the terminal YES outcome to zero and freezes settlement state.
  function _finalizeTerminalAsLoser() private {
    uint256[] memory payouts = new uint256[](2);
    payouts[1] = LibDreamMarginConstants.SETTLEMENT_PAYOUT_DENOMINATOR;
    terminalMarket.resolve(payouts, false);
    settlement.setSettlement(
      terminalOutcomeId >> 8,
      IDreamDexBinarySettlement.SettlementRecord({
        collateralToken: address(collateral),
        backing: uint128(5_000 * ONE),
        finalized: true,
        voided: false,
        settlementFeeBpsTimes1k: 0,
        feeRecipient: address(0xFEE),
        pool: address(terminalPool),
        nonce: 1,
        payoutNumerators: payouts
      })
    );
  }

  /// @notice Sets a deep uncrossed active book.
  function _setActiveBook(uint256 bid) private {
    _activeBid = bid;
    _setBook(activePool, bid);
  }

  /// @notice Sets a deep one-level binary book.
  function _setBook(MockDreamDexBinaryPool pool, uint256 bid) private {
    IDreamDexBinaryPool.BookLevel[] memory bids = new IDreamDexBinaryPool.BookLevel[](1);
    bids[0] = IDreamDexBinaryPool.BookLevel({price: bid, quantity: 5_000 * ONE});
    IDreamDexBinaryPool.BookLevel[] memory asks = new IDreamDexBinaryPool.BookLevel[](1);
    uint256 ask = bid == _STABLE_BID ? 600_000 : ONE - bid;
    asks[0] = IDreamDexBinaryPool.BookLevel({price: ask, quantity: 5_000 * ONE});
    pool.setBookLevels(true, bids);
    pool.setBookLevels(false, asks);
  }

  /// @notice Returns canonical bounded opening parameters.
  function _openParams(MarketKey memory key)
    private
    view
    returns (IDreamMarginController.OpenParams memory params)
  {
    params = IDreamMarginController.OpenParams({
      key: key,
      outcomeIndex: 0,
      initialShares: _INITIAL_SHARES,
      leverageBps: 20_000,
      maxCollateralIn: _OPEN_DEBT,
      minSharesOut: _INITIAL_SHARES,
      limitPrice: _STABLE_BID,
      orderType: LibDreamMarginConstants.ORDER_TYPE_IOC,
      deadline: block.timestamp + 600
    });
  }

  /// @notice Returns one permissive collateral-take request.
  function _take(uint256 positionId, uint256 maxDebtAssets)
    private
    view
    returns (IDreamMarginController.LiquidationParams memory params)
  {
    params = IDreamMarginController.LiquidationParams({
      positionId: positionId,
      maxDebtAssets: maxDebtAssets,
      minSharesOut: 0,
      minCollateralOut: 0,
      limitPrice: 0,
      orderType: 0,
      deadline: block.timestamp,
      route: IDreamMarginController.LiquidationRoute.COLLATERAL_TAKE
    });
  }

  /// @notice Returns one registered generation policy.
  function _generation(MarketKey memory key, bytes32 marketGroup)
    private
    pure
    returns (GenerationConfig memory config)
  {
    config = GenerationConfig({
      key: key,
      risk: RiskConfig({
        maxDebtPerPosition: 20 * ONE,
        maxDebtPerOutcome: 300 * ONE,
        maxDebtPerMarket: 700 * ONE,
        minDebt: ONE,
        initialLtvBps: 6_000,
        maintenanceLtvBps: 7_500,
        collateralFactorBps: 8_000,
        liquidationBonusBps: 500,
        maxSpreadBps: 2_000,
        maxSlippageBps: 1_000,
        maxPositionDepthBps: 5_000,
        maxLeverageBps: 25_000,
        openingCutoff: 1_200,
        reduceOnlyCutoff: 600,
        compressionWindow: 3_600,
        maxBookLevels: 4,
        collateralDecimals: 6,
        outcomeIndex: 0
      }),
      marketGroup: marketGroup,
      enabled: true,
      frozen: false
    });
  }

  /// @notice Returns one immutable oracle policy.
  function _oraclePolicy(MarketKey memory key) private pure returns (OracleConfig memory config) {
    config = OracleConfig({
      key: key,
      minAge: 60,
      updateInterval: 30,
      staleAfter: 120,
      depthQuantity: _DEPTH_QUANTITY,
      maxObservations: 8,
      maxBookLevels: 4,
      enabled: true
    });
  }

  /// @notice Returns protocol-wide fixture risk bounds.
  function _globalRisk() private pure returns (GlobalRiskConfig memory config) {
    config = GlobalRiskConfig({
      maxDebtGlobal: 1_000 * ONE,
      maxDailyRealizedLoss: 100 * ONE,
      maxVaultUtilizationBps: 8_000,
      governanceDelay: GOVERNANCE_DELAY,
      lossWindow: 1 days,
      lossCooldown: 2 days
    });
  }

  /// @notice Returns a registry record for one lane.
  function _moduleMarket(MarketKey memory key, address market, address pool)
    private
    pure
    returns (MockModuleMarket memory record)
  {
    record = MockModuleMarket({
      oracleQuestionId: 1,
      outcomeSlotCount: 2,
      voidPolicy: 0,
      collateral: key.collateral,
      originOperatorId: 0,
      originVenueId: bytes32(0),
      oracleAdapter: address(0xA11),
      creator: address(0xC0DE),
      market: market,
      pool: pool,
      yesId: key.outcomeId,
      noId: key.outcomeId + 1,
      tradingStart: 900_000,
      expiry: EXPIRY
    });
  }

  /// @notice Encodes one exact DreamDEX outcome ID.
  function _outcomeId(address pool, uint64 nonce, uint8 index) private pure returns (uint256 id) {
    id = (uint256(uint160(pool)) << 72) | (uint256(nonce) << 8) | index;
  }

  /// @notice Derives one exact generation key.
  function _deriveKey(MarketKey memory key) private pure returns (bytes32 generationKey) {
    generationKey = keccak256(
      abi.encode(
        key.marketId, key.pool, key.marketNonce, key.outcomeToken, key.outcomeId, key.collateral
      )
    );
  }

  /// @notice Reconstructs a position's pinned generation key.
  function _derivePositionKey(Position memory position)
    private
    view
    returns (bytes32 generationKey)
  {
    generationKey = keccak256(
      abi.encode(
        position.marketId,
        position.pool,
        position.marketNonce,
        position.outcomeToken,
        position.outcomeId,
        address(collateral)
      )
    );
  }

  /// @notice Hashes every immutable identity field retained through closure.
  function _identity(Position memory position) private pure returns (bytes32 digest) {
    digest = keccak256(
      abi.encode(
        position.owner,
        position.marketId,
        position.pool,
        position.outcomeToken,
        position.outcomeId,
        position.initialEquity,
        position.marketNonce,
        position.openedAt,
        position.expiry,
        position.outcomeIndex
      )
    );
  }
}

// forge-lint: disable-end(unsafe-cheatcode, unsafe-typecast, unused-return, reentrancy-no-eth, incorrect-strict-equality, block-timestamp, calls-loop)
