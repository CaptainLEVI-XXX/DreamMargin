// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

// @title DreamMargin controller storage
// @author DreamMargin contributors
// @notice Defines the controller state model and its ERC-7201 namespace accessor.
// @dev Lifecycle modules must reach every mutable controller field through this library.

/// @notice Lifecycle state of one isolated margin position.
enum PositionStatus {
  NONE,
  ACTIVE,
  CLOSING,
  LIQUIDATING,
  RESOLVED,
  CLOSED
}

/// @notice Protocol-wide availability state, independent of position lifecycle state.
enum ProtocolMode {
  ACTIVE,
  REDUCE_ONLY,
  PAUSED
}

/// @notice Identifies one immutable DreamDEX market generation and outcome.
/// @param marketId DreamDEX market identifier.
/// @param pool Recyclable binary pool address.
/// @param marketNonce Generation nonce read from the pool.
/// @param outcomeToken ERC-6909 token contract for this generation.
/// @param outcomeId Exact YES or NO token ID pledged by the position.
/// @param collateral Collateral token backing the market.
struct MarketKey {
  bytes32 marketId;
  address pool;
  uint64 marketNonce;
  address outcomeToken;
  uint256 outcomeId;
  address collateral;
}

/// @notice Stores one owner's isolated leveraged outcome position.
/// @param owner Account entitled to manage and receive residual position value.
/// @param marketId DreamDEX market identifier pinned at opening.
/// @param pool Recyclable pool address pinned at opening.
/// @param outcomeToken ERC-6909 token contract held by the controller.
/// @param outcomeId Exact outcome-token ID attributed to this position.
/// @param shares Outcome shares attributed to the position.
/// @param debtShares Vault debt shares, converted to assets with upward rounding.
/// @param initialEquity Equity recognized at opening in collateral native units.
/// @param marketNonce Pool generation nonce pinned at opening.
/// @param openedAt Opening timestamp in seconds.
/// @param expiry DreamDEX trading expiry in seconds.
/// @param outcomeIndex Zero for YES or one for NO.
/// @param status Current position lifecycle state.
struct Position {
  address owner;
  bytes32 marketId;
  address pool;
  address outcomeToken;
  uint256 outcomeId;
  uint128 shares;
  uint128 debtShares;
  uint128 initialEquity;
  uint64 marketNonce;
  uint40 openedAt;
  uint40 expiry;
  uint8 outcomeIndex;
  PositionStatus status;
}

/// @notice Bounded risk rules for one exact market generation and outcome.
/// @param maxDebtPerPosition Per-position debt ceiling in collateral native units.
/// @param maxDebtPerOutcome Per-generation outcome debt ceiling in collateral native units.
/// @param maxDebtPerMarket Whole-market debt ceiling in collateral native units.
/// @param minDebt Smallest nonzero debt permitted in collateral native units.
/// @param initialLtvBps Maximum opening loan-to-value ratio in basis points.
/// @param maintenanceLtvBps Liquidation loan-to-value boundary in basis points.
/// @param collateralFactorBps Haircut applied to the conservative TWAP cap in basis points.
/// @param liquidationBonusBps Maximum liquidator incentive in basis points.
/// @param maxSpreadBps Largest admitted executable spread in basis points.
/// @param maxSlippageBps Largest admitted size-aware execution slippage in basis points.
/// @param maxPositionDepthBps Largest position share of walked visible depth in basis points.
/// @param maxLeverageBps Largest post-trade gross leverage in basis points, where 10,000 is 1x.
/// @param openingCutoff Seconds before expiry when new borrowing stops.
/// @param reduceOnlyCutoff Seconds before expiry when every generation becomes reduce-only.
/// @param compressionWindow Seconds over which maintenance requirements tighten monotonically.
/// @param maxBookLevels Maximum order-book levels included in a conservative walk.
/// @param collateralDecimals Precision of the collateral token.
/// @param outcomeIndex Zero for YES or one for NO.
struct RiskConfig {
  uint256 maxDebtPerPosition;
  uint256 maxDebtPerOutcome;
  uint256 maxDebtPerMarket;
  uint256 minDebt;
  uint16 initialLtvBps;
  uint16 maintenanceLtvBps;
  uint16 collateralFactorBps;
  uint16 liquidationBonusBps;
  uint16 maxSpreadBps;
  uint16 maxSlippageBps;
  uint16 maxPositionDepthBps;
  uint32 maxLeverageBps;
  uint40 openingCutoff;
  uint40 reduceOnlyCutoff;
  uint40 compressionWindow;
  uint16 maxBookLevels;
  uint8 collateralDecimals;
  uint8 outcomeIndex;
}

/// @notice Registered controller configuration for one immutable generation tuple.
/// @param key Full tuple whose hash indexes this configuration.
/// @param risk Bounded economic rules for the generation outcome.
/// @param marketGroup Shared exposure bucket for both outcomes of one market.
/// @param enabled Whether the generation can admit new positions.
/// @param frozen Whether the guardian has blocked risk increases for the generation.
struct GenerationConfig {
  MarketKey key;
  RiskConfig risk;
  bytes32 marketGroup;
  bool enabled;
  bool frozen;
}

/// @notice Protocol-wide risk bounds not specific to a market generation.
/// @param maxDebtGlobal Aggregate performing debt ceiling in collateral native units.
/// @param maxDailyRealizedLoss Loss threshold that permissionlessly activates reduce-only mode.
/// @param maxVaultUtilizationBps Maximum vault utilization after new borrowing.
/// @param governanceDelay Delay before a scheduled risk increase can execute, in seconds.
/// @param lossWindow Duration of the rolling realized-loss bucket, in seconds.
/// @param lossCooldown Minimum delay before governance may restore borrowing after a loss trip.
struct GlobalRiskConfig {
  uint256 maxDebtGlobal;
  uint256 maxDailyRealizedLoss;
  uint16 maxVaultUtilizationBps;
  uint40 governanceDelay;
  uint40 lossWindow;
  uint40 lossCooldown;
}

/// @notice One delayed governance operation committed by its calldata hash.
/// @param payloadHash Hash of the exact action and parameters to execute.
/// @param executableAt Earliest execution timestamp in seconds.
/// @param proposer Governance account that scheduled the change.
struct PendingChange {
  bytes32 payloadHash;
  uint40 executableAt;
  address proposer;
}

// ERC-7201 slot for `dreammargin.storage.Controller`.
// Derivation: `keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff))`.
// Value: `0xbb4b9b7574d0b39d8688a06b15e345f90ceb8be3084b71b5f471527c6bf5d500`.
bytes32 constant DREAM_MARGIN_STORAGE_SLOT =
  0xbb4b9b7574d0b39d8688a06b15e345f90ceb8be3084b71b5f471527c6bf5d500;

/// @title DreamMargin controller storage accessor
/// @author DreamMargin contributors
/// @notice Accesses and mutates DreamMargin controller state.
/// @dev Lifecycle modules must reach every mutable controller field through this library.
library LibDreamMarginStorage {
  /// @notice Complete mutable state of the DreamMargin controller.
  /// @param positions Position records keyed by IDs beginning at one.
  /// @param generations Registered generation configurations keyed by their full tuple hash.
  /// @param attributedShares Aggregate live position shares by outcome token and exact ID.
  /// @param outcomeDebtShares Aggregate debt shares by generation key.
  /// @param marketDebtShares Aggregate debt shares by market exposure group.
  /// @param roles Bitmapped roles assigned to each account.
  /// @param authorizationNonces Replay-protection nonces reserved for owner-signed actions.
  /// @param pendingChanges Delayed governance operations keyed by action identifier.
  /// @param lossRecognized Whether terminal bad debt was already finalized for a position.
  /// @param globalRisk Protocol-wide bounded risk configuration.
  /// @param totalDebtShares Controller debt shares recognized by the vault.
  /// @param nextPositionId Next identifier allocated, initialized to one.
  /// @param dailyRealizedLoss Loss accumulated in the active loss window.
  /// @param lossWindowStartedAt Start timestamp of the active realized-loss window.
  /// @param reduceOnlyTriggeredAt Timestamp of the latest loss-triggered reduce-only transition.
  /// @param mode Protocol-wide availability state.
  /// @param reentrancyStatus Current reentrancy-guard state.
  /// @param initialized Whether controller initialization has completed.
  struct State {
    mapping(uint256 positionId => Position position) positions;
    mapping(bytes32 generationKey => GenerationConfig config) generations;
    mapping(address token => mapping(uint256 id => uint256 shares)) attributedShares;
    mapping(bytes32 generationKey => uint256 debtShares) outcomeDebtShares;
    mapping(bytes32 marketGroup => uint256 debtShares) marketDebtShares;
    mapping(address account => uint256 roleBits) roles;
    mapping(address owner => uint256 nonce) authorizationNonces;
    mapping(bytes32 changeId => PendingChange change_) pendingChanges;
    mapping(uint256 positionId => bool recognized) lossRecognized;
    GlobalRiskConfig globalRisk;
    uint256 totalDebtShares;
    uint256 nextPositionId;
    uint256 dailyRealizedLoss;
    uint40 lossWindowStartedAt;
    uint40 reduceOnlyTriggeredAt;
    ProtocolMode mode;
    uint8 reentrancyStatus;
    bool initialized;
  }

  /// @notice Returns the controller state stored at its ERC-7201 namespace.
  /// @dev Memory layout: `slot` is one stack word containing the namespace root.
  ///      1. Bind the returned storage pointer to that root.
  ///      Safety Considerations: THE LITERAL SLOT DERIVATION IS VERIFIED BY TEST;
  ///      THIS ACCESSOR DOES NOT VALIDATE FIELD LAYOUT OR UPGRADE COMPATIBILITY.
  /// @return self Storage reference to the controller state.
  function get() internal pure returns (State storage self) {
    bytes32 slot = DREAM_MARGIN_STORAGE_SLOT;
    assembly ("memory-safe") {
      self.slot := slot
    }
  }

  /// @notice Derives the identity key for one complete market-generation tuple.
  /// @param self Market-generation tuple to hash.
  /// @return key_ Collision-resistant generation identifier.
  function generationKey(MarketKey memory self) internal pure returns (bytes32 key_) {
    key_ = keccak256(
      abi.encode(
        self.marketId,
        self.pool,
        self.marketNonce,
        self.outcomeToken,
        self.outcomeId,
        self.collateral
      )
    );
  }
}
