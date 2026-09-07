// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller interface
/// @author DreamMargin contributors
/// @notice Exposes isolated-position lifecycle actions and transparent state views.
/// @dev Risk-increasing calls bind the exact DreamDEX generation, deadline, and execution limits.

import {
  GenerationConfig,
  GlobalRiskConfig,
  MarketKey,
  Position,
  ProtocolMode,
  SeriesPolicy
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {OracleConfig} from "src/libs/dreammargin/LibDreamDexMarkOracleStorage.sol";

interface IDreamMarginController {
  /// @notice Emitted whenever an account's complete role bitmap changes.
  /// @param account Account whose roles changed.
  /// @param previousRoles Previous role bitmap.
  /// @param newRoles Replacement role bitmap.
  event RolesUpdated(address indexed account, uint256 previousRoles, uint256 newRoles);

  /// @notice Emitted when the protocol enters a new operating mode.
  /// @param previousMode Mode before the transition.
  /// @param newMode Mode after the transition.
  /// @param caller Account initiating or executing the transition.
  event ProtocolModeUpdated(
    ProtocolMode indexed previousMode, ProtocolMode indexed newMode, address indexed caller
  );

  /// @notice Emitted when one exact generation is registered or replaced after delay.
  /// @param generationKey Full generation identifier.
  /// @param enabled Whether new positions are admitted.
  /// @param frozen Whether emergency freeze is active.
  event GenerationUpdated(bytes32 indexed generationKey, bool enabled, bool frozen);

  /// @notice Emitted when an emergency actor freezes one generation.
  /// @param generationKey Full generation identifier.
  /// @param caller Guardian or governance caller.
  event GenerationFrozen(bytes32 indexed generationKey, address indexed caller);

  /// @notice Emitted when one reusable DreamDEX-origin policy is registered or replaced.
  /// @param policyId Governance-selected policy identifier.
  /// @param identity Hash of creator, venue, operator, and collateral.
  /// @param enabled Whether matching generations may admit new risk.
  /// @param frozen Whether the policy is emergency-frozen.
  event SeriesPolicyUpdated(
    bytes32 indexed policyId, bytes32 indexed identity, bool enabled, bool frozen
  );

  /// @notice Emitted when an emergency actor freezes one reusable series policy.
  /// @param policyId Frozen policy identifier.
  /// @param caller Guardian or governance caller.
  event SeriesPolicyFrozen(bytes32 indexed policyId, address indexed caller);

  /// @notice Emitted when a matching current generation is activated without governance.
  /// @param generationKey Full activated generation identifier.
  /// @param policyId Reusable policy that admitted the generation.
  /// @param marketGroup Exposure bucket shared by both generation outcomes.
  /// @param outcomeIndex Zero for YES or one for NO.
  event SeriesGenerationActivated(
    bytes32 indexed generationKey,
    bytes32 indexed policyId,
    bytes32 indexed marketGroup,
    uint8 outcomeIndex
  );

  /// @notice Emitted when exact execution payload is committed for delayed execution.
  /// @param changeId Caller-selected unique change identifier.
  /// @param payloadHash Hash of the exact execution selector and arguments.
  /// @param executableAt Earliest execution timestamp.
  event ChangeScheduled(bytes32 indexed changeId, bytes32 indexed payloadHash, uint40 executableAt);

  /// @notice Emitted when a pending delayed change is cancelled.
  /// @param changeId Cancelled change identifier.
  /// @param caller Governance or guardian caller.
  event ChangeCancelled(bytes32 indexed changeId, address indexed caller);

  /// @notice Emitted after a committed delayed change executes.
  /// @param changeId Executed change identifier.
  /// @param payloadHash Verified execution payload hash.
  event ChangeExecuted(bytes32 indexed changeId, bytes32 indexed payloadHash);

  /// @notice Emitted when delayed governance releases demonstrably excess reserve capital.
  /// @param recipient Immutable protocol fee recipient receiving the assets.
  /// @param assets Reserve assets released.
  /// @param reserveSharesBurned Locked reserve shares burned.
  event ProtocolReserveWithdrawn(
    address indexed recipient, uint256 assets, uint256 reserveSharesBurned
  );

  /// @notice Returns the immutable DreamDEX module.
  /// @return module_ Bound module address.
  function module() external view returns (address module_);

  /// @notice Returns the immutable collateral vault.
  /// @return vault_ Bound vault address.
  function vault() external view returns (address vault_);

  /// @notice Returns the immutable mark oracle.
  /// @return oracle_ Bound oracle address.
  function oracle() external view returns (address oracle_);

  /// @notice Returns the immutable protocol fee recipient.
  /// @return recipient Fee recipient address.
  function feeRecipient() external view returns (address recipient);

  /// @notice Returns the immutable position-opening lifecycle facet.
  /// @return facet Predeployed facet reached only by opening selectors.
  function positionOpenFacet() external view returns (address facet);

  /// @notice Returns the immutable ordinary position-reduction lifecycle facet.
  /// @return facet Predeployed facet reached only by repayment and owner-exit selectors.
  function positionCloseFacet() external view returns (address facet);

  /// @notice Returns the immutable permissionless liquidation lifecycle facet.
  /// @return facet Predeployed facet reached only by the liquidation selector.
  function positionLiquidationFacet() external view returns (address facet);

  /// @notice Returns the immutable terminal-settlement facet.
  /// @return facet Settlement facet address.
  function positionSettlementFacet() external view returns (address facet);

  /// @notice Returns an account's complete role bitmap.
  /// @param account Account queried.
  /// @return roles Assigned role bits.
  function rolesOf(address account) external view returns (uint256 roles);

  /// @notice Returns the current global risk configuration.
  /// @return config Current global bounds and delays.
  function globalRiskConfig() external view returns (GlobalRiskConfig memory config);

  /// @notice Commits an exact high-impact action for delayed execution.
  /// @param changeId Unique pending change identifier.
  /// @param payloadHash Hash of execution selector and arguments.
  function scheduleChange(bytes32 changeId, bytes32 payloadHash) external;

  /// @notice Schedules only a generation-policy change as risk steward or governance.
  /// @param changeId Unique pending change identifier.
  /// @param generationKey Full generation identifier.
  /// @param config Proposed controller generation policy.
  /// @param oracleConfig Proposed immutable first-registration oracle policy.
  function scheduleGenerationChange(
    bytes32 changeId,
    bytes32 generationKey,
    GenerationConfig calldata config,
    OracleConfig calldata oracleConfig
  ) external;

  /// @notice Schedules one reusable series-policy change as risk steward or governance.
  /// @param changeId Unique pending change identifier.
  /// @param policyId Governance-selected policy identifier.
  /// @param policy Proposed DreamDEX-origin, risk, and oracle policy.
  function scheduleSeriesPolicyChange(
    bytes32 changeId,
    bytes32 policyId,
    SeriesPolicy calldata policy
  ) external;

  /// @notice Cancels a pending delayed action as governance or guardian.
  /// @param changeId Pending change identifier.
  function cancelChange(bytes32 changeId) external;

  /// @notice Applies a stricter emergency mode without delay.
  /// @param mode New mode, which must be at least as restrictive as current mode.
  function setEmergencyMode(ProtocolMode mode) external;

  /// @notice Freezes new risk for one registered generation without delay.
  /// @param generationKey Registered generation identifier.
  function freezeGeneration(bytes32 generationKey) external;

  /// @notice Freezes one series policy and every generation admitted through it.
  /// @param policyId Registered series-policy identifier.
  function freezeSeriesPolicy(bytes32 policyId) external;

  /// @notice Executes a committed complete role-bitmap replacement.
  /// @param changeId Scheduled change identifier.
  /// @param account Account whose roles are replaced.
  /// @param roles Replacement allowed role bitmap.
  function executeRoleChange(bytes32 changeId, address account, uint256 roles) external;

  /// @notice Executes a committed global-risk replacement.
  /// @param changeId Scheduled change identifier.
  /// @param config Replacement global risk configuration.
  function executeGlobalRiskChange(bytes32 changeId, GlobalRiskConfig calldata config) external;

  /// @notice Executes a committed generation registration or risk-policy replacement.
  /// @param changeId Scheduled change identifier.
  /// @param generationKey Full generation identifier.
  /// @param config Replacement controller generation policy.
  /// @param oracleConfig Immutable oracle policy used only for first registration.
  function executeGenerationChange(
    bytes32 changeId,
    bytes32 generationKey,
    GenerationConfig calldata config,
    OracleConfig calldata oracleConfig
  ) external;

  /// @notice Executes a committed reusable series-policy registration or replacement.
  /// @param changeId Scheduled change identifier.
  /// @param policyId Governance-selected policy identifier.
  /// @param policy Replacement DreamDEX-origin, risk, and oracle policy.
  function executeSeriesPolicyChange(
    bytes32 changeId,
    bytes32 policyId,
    SeriesPolicy calldata policy
  ) external;

  /// @notice Permissionlessly activates one exact current outcome under a registered policy.
  /// @param key Full current DreamDEX generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @return generationKey Hash identifying the activated tuple.
  /// @return policyId Reusable series policy that admitted the tuple.
  function activateSeriesGeneration(MarketKey calldata key, uint8 outcomeIndex)
    external
    returns (bytes32 generationKey, bytes32 policyId);

  /// @notice Executes a committed restoration to a less restrictive protocol mode.
  /// @param changeId Scheduled change identifier.
  /// @param mode Target operating mode.
  function executeModeChange(bytes32 changeId, ProtocolMode mode) external;

  /// @notice Executes a committed reserve release while paused and fully debt-free.
  /// @param changeId Scheduled change identifier.
  /// @param assets Exact reserve assets sent to the immutable fee recipient.
  /// @return reserveSharesBurned Non-redeemable reserve shares burned by the vault.
  function executeReserveWithdrawal(bytes32 changeId, uint256 assets)
    external
    returns (uint256 reserveSharesBurned);

  /// @notice Direct-sale and collateral-take liquidation routes supported by the MVP.
  enum LiquidationRoute {
    COLLATERAL_TAKE,
    DIRECT_SALE
  }

  /// @notice User bounds for one atomic leveraged opening.
  /// @param key Exact DreamDEX generation and outcome pledged.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param initialShares Existing owner shares transferred as initial equity.
  /// @param leverageBps Requested nominal gross leverage, where 10,000 is 1x.
  /// @param maxCollateralIn Maximum borrowed collateral the order may spend.
  /// @param minSharesOut Minimum additional outcome shares required from actual balance deltas.
  /// @param limitPrice YES-side DreamDEX limit price in pool raw units.
  /// @param orderType Immediate DreamDEX order type, FOK or IOC only.
  /// @param deadline Latest transaction timestamp in seconds.
  struct OpenParams {
    MarketKey key;
    uint8 outcomeIndex;
    uint256 initialShares;
    uint32 leverageBps;
    uint256 maxCollateralIn;
    uint256 minSharesOut;
    uint256 limitPrice;
    uint8 orderType;
    uint256 deadline;
  }

  /// @notice User bounds for one collateral-funded atomic leveraged opening.
  /// @param key Exact DreamDEX generation and outcome purchased.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param targetShares Exact final outcome quantity purchased into the position.
  /// @param leverageBps Requested gross leverage ceiling, where 10,000 is 1x.
  /// @param maxUserCollateralIn Maximum owner collateral pulled in native units.
  /// @param maxDebt Maximum vault collateral debt admitted in native units.
  /// @param limitPrice YES-side DreamDEX limit price in pool raw units.
  /// @param deadline Latest transaction timestamp in seconds.
  struct OpenFromCollateralParams {
    MarketKey key;
    uint8 outcomeIndex;
    uint256 targetShares;
    uint32 leverageBps;
    uint256 maxUserCollateralIn;
    uint256 maxDebt;
    uint256 limitPrice;
    uint256 deadline;
  }

  /// @notice User bounds for selling collateral shares and repaying debt.
  /// @param positionId Position being reduced.
  /// @param sharesToSell Maximum recorded outcome shares offered to DreamDEX.
  /// @param minCollateralOut Minimum actual collateral proceeds accepted.
  /// @param limitPrice YES-side DreamDEX limit price in pool raw units.
  /// @param orderType Immediate DreamDEX order type, FOK or IOC only.
  /// @param deadline Latest transaction timestamp in seconds.
  struct DeleverageParams {
    uint256 positionId;
    uint256 sharesToSell;
    uint256 minCollateralOut;
    uint256 limitPrice;
    uint8 orderType;
    uint256 deadline;
  }

  /// @notice User bounds for closing into collateral or repaying to withdraw outcomes.
  /// @param positionId Position being closed.
  /// @param maxRepayAssets Maximum owner collateral pulled for any debt shortfall.
  /// @param minCollateralOut Minimum actual sale proceeds when outcomes are sold.
  /// @param limitPrice YES-side DreamDEX limit price in pool raw units.
  /// @param orderType Immediate DreamDEX order type, FOK or IOC only.
  /// @param deadline Latest transaction timestamp in seconds.
  /// @param withdrawOutcome True to repay externally and withdraw outcome shares without a sale.
  struct CloseParams {
    uint256 positionId;
    uint256 maxRepayAssets;
    uint256 minCollateralOut;
    uint256 limitPrice;
    uint8 orderType;
    uint256 deadline;
    bool withdrawOutcome;
  }

  /// @notice Bounds and route for one permissionless liquidation.
  /// @param positionId Position being liquidated.
  /// @param maxDebtAssets Maximum collateral the liquidator pays or the sale repays.
  /// @param minSharesOut Minimum outcome shares received by a collateral-take liquidator.
  /// @param minCollateralOut Minimum direct-sale proceeds accepted.
  /// @param limitPrice YES-side DreamDEX limit price in pool raw units.
  /// @param orderType Immediate DreamDEX order type, FOK or IOC only.
  /// @param deadline Latest transaction timestamp in seconds.
  /// @param route Selected MVP liquidation route.
  struct LiquidationParams {
    uint256 positionId;
    uint256 maxDebtAssets;
    uint256 minSharesOut;
    uint256 minCollateralOut;
    uint256 limitPrice;
    uint8 orderType;
    uint256 deadline;
    LiquidationRoute route;
  }

  /// @notice Emitted after an atomic open records actual debt and acquired shares.
  /// @param positionId Newly allocated position identifier.
  /// @param owner Position owner and source of the initial exact-ID collateral.
  /// @param generationKey Full DreamDEX generation key.
  /// @param initialShares Existing shares deposited by the owner.
  /// @param sharesBought Additional shares received from actual execution deltas.
  /// @param debtAssets Collateral debt created in native units.
  event PositionOpened(
    uint256 indexed positionId,
    address indexed owner,
    bytes32 indexed generationKey,
    uint256 initialShares,
    uint256 sharesBought,
    uint256 debtAssets
  );

  /// @notice Emitted after owner collateral and vault debt fund one atomic outcome purchase.
  /// @param positionId Newly allocated position identifier.
  /// @param owner Position owner and collateral payer.
  /// @param userAssetsSpent Owner collateral consumed by the actual DreamDEX fill.
  event CollateralFundedPositionOpened(
    uint256 indexed positionId, address indexed owner, uint256 userAssetsSpent
  );

  /// @notice Emitted when exact outcome collateral is added without increasing debt.
  /// @param positionId Position receiving collateral.
  /// @param owner Account supplying the exact recorded outcome ID.
  /// @param shares Outcome shares added.
  event CollateralAdded(uint256 indexed positionId, address indexed owner, uint256 shares);

  /// @notice Emitted when an owner safely withdraws attributed outcome collateral.
  /// @param positionId Position whose attributed collateral decreased.
  /// @param owner Position owner receiving the exact outcome ID.
  /// @param shares Outcome shares withdrawn.
  event CollateralWithdrawn(uint256 indexed positionId, address indexed owner, uint256 shares);

  /// @notice Emitted after collateral repayment retires debt shares.
  /// @param positionId Position whose debt decreased.
  /// @param payer Account supplying repayment collateral.
  /// @param assetsRepaid Collateral actually received by the vault.
  /// @param debtSharesRepaid Debt shares retired.
  event PositionRepaid(
    uint256 indexed positionId,
    address indexed payer,
    uint256 assetsRepaid,
    uint256 debtSharesRepaid
  );

  /// @notice Emitted after an outcome sale applies actual proceeds debt-first.
  /// @param positionId Position reduced.
  /// @param sharesSold Actual outcome shares removed.
  /// @param assetsRepaid Actual collateral applied to vault debt.
  event PositionDeleveraged(uint256 indexed positionId, uint256 sharesSold, uint256 assetsRepaid);

  /// @notice Emitted after a position reaches terminal zero-debt, zero-collateral state.
  /// @param positionId Closed position identifier.
  /// @param owner Position owner.
  /// @param assetsOut Residual collateral returned after repayment.
  /// @param sharesOut Residual outcome shares returned after repayment.
  event PositionClosed(
    uint256 indexed positionId, address indexed owner, uint256 assetsOut, uint256 sharesOut
  );

  /// @notice Emitted after an eligible position is liquidated through a bounded route.
  /// @param positionId Liquidated position identifier.
  /// @param liquidator Account that supplied capital or executed the liquidation.
  /// @param route Selected liquidation route.
  /// @param repaid Collateral applied to debt.
  /// @param seized Outcome shares removed from the owner position.
  /// @param incentive Liquidator incentive in collateral native units.
  event PositionLiquidated(
    uint256 indexed positionId,
    address indexed liquidator,
    LiquidationRoute route,
    uint256 repaid,
    uint256 seized,
    uint256 incentive
  );

  /// @notice Emitted after terminal DreamDEX redemption and loss finalization.
  /// @param positionId Settled position identifier.
  /// @param repaid Collateral applied to debt.
  /// @param ownerAssets Genuine surplus returned to the owner.
  /// @param badDebt Receivable removed after reserve application.
  event PositionSettled(
    uint256 indexed positionId, uint256 repaid, uint256 ownerAssets, uint256 badDebt
  );

  /// @notice Emitted when actual collateral is added to the first-loss reserve.
  /// @param payer Account supplying reserve collateral.
  /// @param assets Exact collateral received by the vault.
  /// @param reserveShares Non-redeemable reserve shares minted.
  event ReserveFunded(address indexed payer, uint256 assets, uint256 reserveShares);

  /// @notice Emitted when actual post-write-off collateral reaches the vault.
  /// @param payer Account supplying recovered collateral.
  /// @param assets Exact collateral recorded as recovery.
  event BadDebtRecovered(address indexed payer, uint256 assets);

  /// @notice Opens one isolated leveraged position atomically.
  /// @param params Exact generation, collateral, leverage, price, fill, and deadline bounds.
  /// @return positionId Newly allocated position identifier.
  /// @return sharesBought Additional outcome shares received from actual execution deltas.
  /// @return debtAssets Collateral debt created in native units.
  function openPosition(OpenParams calldata params)
    external
    returns (uint256 positionId, uint256 sharesBought, uint256 debtAssets);

  /// @notice Opens one exact-size leveraged position from owner collateral in one atomic action.
  /// @param params Exact generation, share target, leverage, spend, debt, price, and time bounds.
  /// @return positionId Newly allocated position identifier.
  /// @return userAssetsSpent Owner collateral consumed by execution, rounded from actual deltas.
  /// @return sharesBought Exact outcome shares acquired into controller custody.
  /// @return debtAssets Final vault collateral debt after unused borrowing is returned.
  function openFromCollateral(OpenFromCollateralParams calldata params)
    external
    returns (uint256 positionId, uint256 userAssetsSpent, uint256 sharesBought, uint256 debtAssets);

  /// @notice Adds the exact recorded outcome ID without borrowing or trading.
  /// @param positionId Position receiving collateral.
  /// @param shares Outcome shares transferred from the caller.
  function addCollateral(uint256 positionId, uint256 shares) external;

  /// @notice Repays up to a bounded collateral amount in every protocol mode.
  /// @param positionId Position whose debt decreases.
  /// @param maxAssets Maximum collateral pulled from the payer.
  /// @return assetsRepaid Collateral actually received by the vault.
  function repay(uint256 positionId, uint256 maxAssets) external returns (uint256 assetsRepaid);

  /// @notice Withdraws debt-free or conservatively excess outcome collateral.
  /// @param positionId Position whose attributed shares decrease.
  /// @param shares Shares transferred to the owner.
  function withdrawCollateral(uint256 positionId, uint256 shares) external;

  /// @notice Sells outcome shares and applies actual collateral proceeds debt-first.
  /// @param params Position, sale, price, fill, and deadline bounds.
  /// @return sharesSold Actual outcome shares sold.
  /// @return assetsRepaid Actual collateral applied to debt.
  function deleverage(DeleverageParams calldata params)
    external
    returns (uint256 sharesSold, uint256 assetsRepaid);

  /// @notice Closes a position into collateral or repaid outcome shares.
  /// @param params Position, repayment, execution, and output choices.
  /// @return assetsOut Residual collateral returned after debt repayment.
  /// @return sharesOut Residual outcome shares returned after debt repayment.
  function close(CloseParams calldata params)
    external
    returns (uint256 assetsOut, uint256 sharesOut);

  /// @notice Liquidates an unhealthy nonterminal position through a bounded MVP route.
  /// @param params Position, route, payment, execution, and deadline bounds.
  /// @return repaid Collateral applied to debt.
  /// @return seized Outcome shares removed from the owner position.
  /// @return incentive Liquidator incentive in collateral native units.
  function liquidate(LiquidationParams calldata params)
    external
    returns (uint256 repaid, uint256 seized, uint256 incentive);

  /// @notice Redeems a terminal DreamDEX outcome and finalizes debt or loss exactly once.
  /// @param positionId Position settled.
  /// @return repaid Collateral applied to debt.
  /// @return ownerAssets Genuine surplus returned to the owner.
  /// @return badDebt Receivable removed after reserve application.
  function settle(uint256 positionId)
    external
    returns (uint256 repaid, uint256 ownerAssets, uint256 badDebt);

  /// @notice Supplies actual collateral to the non-redeemable first-loss reserve.
  /// @param assets Exact collateral pulled from the caller.
  /// @return reserveShares Non-redeemable reserve shares minted by the vault.
  function fundReserve(uint256 assets) external returns (uint256 reserveShares);

  /// @notice Supplies actual collateral against previously realized bad debt.
  /// @param assets Exact collateral pulled from the caller.
  function recordRecovery(uint256 assets) external;

  /// @notice Returns one stored position.
  /// @param positionId Position identifier.
  /// @return position Stored position state.
  function getPosition(uint256 positionId) external view returns (Position memory position);

  /// @notice Returns a bounded page of IDs allocated to one immutable position owner.
  /// @param owner Position owner queried.
  /// @param offset Zero-based offset into the owner's opening-order list.
  /// @param limit Maximum IDs requested, capped at one hundred.
  /// @return ids Position IDs in ascending allocation order.
  /// @return total Total positions ever opened by the owner.
  function positionsOf(address owner, uint256 offset, uint256 limit)
    external
    view
    returns (uint256[] memory ids, uint256 total);

  /// @notice Returns one registered generation configuration.
  /// @param generationKey Full market-generation key.
  /// @return config Registered generation state and risk bounds.
  function getGeneration(bytes32 generationKey)
    external
    view
    returns (GenerationConfig memory config);

  /// @notice Returns the configured maximum resulting position size for one generation.
  /// @param generationKey Full market-generation key.
  /// @return shares Maximum total outcome shares admitted, rounded down.
  function maximumPositionShares(bytes32 generationKey) external view returns (uint256 shares);

  /// @notice Returns one reusable series policy.
  /// @param policyId Governance-selected policy identifier.
  /// @return policy Stored DreamDEX-origin, risk, and oracle policy.
  function getSeriesPolicy(bytes32 policyId) external view returns (SeriesPolicy memory policy);

  /// @notice Resolves the reusable policy for the module's current market record.
  /// @param marketId DreamDEX market identifier.
  /// @return policyId Matching policy identifier, or zero when none is registered.
  /// @return eligible Whether identity, interval, and policy state currently admit activation.
  function policyFor(bytes32 marketId) external view returns (bytes32 policyId, bool eligible);

  /// @notice Returns the series policy that admitted an exact generation.
  /// @param generationKey Full generation identifier.
  /// @return policyId Linked policy identifier, or zero for manual registrations.
  function policyForGeneration(bytes32 generationKey) external view returns (bytes32 policyId);

  /// @notice Returns the current protocol-wide operating mode.
  /// @return mode Current active, reduce-only, or paused mode.
  function protocolMode() external view returns (ProtocolMode mode);

  /// @notice Returns the current realized-loss window and restoration cooldown anchor.
  /// @return dailyLoss Loss accumulated in the active fixed window.
  /// @return windowStartedAt Start timestamp of the active loss window.
  /// @return reduceOnlyTriggeredAt Latest threshold-breaching loss timestamp.
  function lossState()
    external
    view
    returns (uint256 dailyLoss, uint40 windowStartedAt, uint40 reduceOnlyTriggeredAt);
}
