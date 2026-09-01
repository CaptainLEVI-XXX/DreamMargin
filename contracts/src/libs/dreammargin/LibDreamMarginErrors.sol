// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin protocol errors
/// @author DreamMargin contributors
/// @notice Defines namespaced failures with the values that violated protocol rules.
/// @dev Callers revert with these errors directly; no assembly error shim is used.
library LibDreamMarginErrors {
  /// @notice Raised when an address-valued dependency or recipient is zero.
  /// @param field Identifier of the address field.
  error ZeroAddress(bytes32 field);

  /// @notice Raised when a lifecycle facet address has no deployed runtime code.
  /// @param facet Address supplied as an immutable lifecycle facet.
  error InvalidFacet(address facet);

  /// @notice Raised when an amount that must be positive is zero.
  /// @param amount Offending zero amount.
  error ZeroAmount(uint256 amount);

  /// @notice Raised when a mathematical denominator or grid is zero.
  /// @param field Identifier of the zero denominator.
  error ZeroDenominator(bytes32 field);

  /// @notice Raised when venue quantization removes an otherwise nonzero action.
  /// @param requested Nonzero value before quantization.
  /// @param quantum Tick or lot increment applied.
  error QuantizedToZero(uint256 requested, uint256 quantum);

  /// @notice Raised when a caller lacks a required role bit.
  /// @param account Unauthorized caller.
  /// @param requiredRole Required role bit.
  /// @param actualRoles Roles currently assigned to the caller.
  error Unauthorized(address account, uint256 requiredRole, uint256 actualRoles);

  /// @notice Raised when a caller is not the recorded position owner.
  /// @param account Unauthorized caller.
  /// @param owner Recorded position owner.
  /// @param positionId Position being accessed.
  error NotPositionOwner(address account, address owner, uint256 positionId);

  /// @notice Raised when initialization is attempted more than once.
  /// @param initialized Existing initialization state.
  error AlreadyInitialized(bool initialized);

  /// @notice Raised when an action is unavailable in the current protocol mode.
  /// @param mode Current protocol mode encoding.
  /// @param action Identifier of the rejected action.
  error ActionBlocked(uint8 mode, bytes4 action);

  /// @notice Raised when a position identifier does not refer to an existing position.
  /// @param positionId Missing position identifier.
  error PositionNotFound(uint256 positionId);

  /// @notice Raised when a position is in the wrong lifecycle state.
  /// @param positionId Position being changed.
  /// @param actualStatus Current status encoding.
  /// @param expectedStatus Required status encoding.
  error InvalidPositionStatus(uint256 positionId, uint8 actualStatus, uint8 expectedStatus);

  /// @notice Raised when a configured generation does not match the supplied tuple.
  /// @param expectedKey Registered generation key.
  /// @param actualKey Key derived from the supplied generation.
  error GenerationMismatch(bytes32 expectedKey, bytes32 actualKey);

  /// @notice Raised when a deployed integration field differs from its pinned value.
  /// @param field Identifier of the integration field.
  /// @param expected Expected value encoded as one word.
  /// @param actual Value returned by the deployed integration.
  error IntegrationValueMismatch(bytes32 field, bytes32 expected, bytes32 actual);

  /// @notice Raised when a market generation is not enabled for new risk.
  /// @param generationKey Disabled or unknown generation key.
  error UnsupportedGeneration(bytes32 generationKey);

  /// @notice Raised when a frozen generation is used for a forbidden action.
  /// @param generationKey Frozen generation key.
  error GenerationFrozen(bytes32 generationKey);

  /// @notice Raised when a recyclable pool reports a different nonce.
  /// @param pool Pool address read.
  /// @param expectedNonce Registered generation nonce.
  /// @param actualNonce Nonce currently reported by the pool.
  error PoolRecycled(address pool, uint64 expectedNonce, uint64 actualNonce);

  /// @notice Raised when a DreamDEX market has an unsuitable status.
  /// @param market Market state contract.
  /// @param actualStatus Current status encoding.
  /// @param requiredStatus Required status encoding.
  error InvalidMarketStatus(address market, uint8 actualStatus, uint8 requiredStatus);

  /// @notice Raised when a user-provided deadline has passed.
  /// @param deadline Deadline in seconds.
  /// @param currentTime Current timestamp in seconds.
  error DeadlineExpired(uint256 deadline, uint256 currentTime);

  /// @notice Raised when an order deadline exceeds the pool generation's expiry ceiling.
  /// @param deadlineNs Requested order deadline in nanoseconds.
  /// @param maximumNs Pool order-expiry ceiling in nanoseconds.
  error OrderDeadlineExceeded(uint256 deadlineNs, uint256 maximumNs);

  /// @notice Raised when a value cannot be represented by a narrowed storage type.
  /// @param field Identifier of the bounded field.
  /// @param value Offending value.
  /// @param maximum Largest accepted value.
  error ValueOutOfBounds(bytes32 field, uint256 value, uint256 maximum);

  /// @notice Raised when collateral precision exceeds the supported domain.
  /// @param decimals Offending token precision.
  /// @param maximum Largest supported precision.
  error UnsupportedDecimals(uint8 decimals, uint8 maximum);

  /// @notice Raised when a basis-point value exceeds one hundred percent.
  /// @param field Identifier of the basis-point field.
  /// @param value Offending basis-point value.
  error InvalidBps(bytes32 field, uint256 value);

  /// @notice Raised when an order price does not lie on the DreamDEX tick grid.
  /// @param price Offending YES-side price.
  /// @param tickSize Required price increment.
  error InvalidTick(uint256 price, uint256 tickSize);

  /// @notice Raised when an order quantity does not lie on the DreamDEX lot grid.
  /// @param quantity Offending outcome quantity.
  /// @param lotSize Required quantity increment.
  error InvalidLot(uint256 quantity, uint256 lotSize);

  /// @notice Raised when an order is smaller than the venue minimum.
  /// @param quantity Offending outcome quantity.
  /// @param minimum Minimum accepted outcome quantity.
  error QuantityBelowMinimum(uint256 quantity, uint256 minimum);

  /// @notice Raised when an order type could leave a resting order.
  /// @param orderType Offending DreamDEX order type.
  error UnsupportedOrderType(uint8 orderType);

  /// @notice Raised when DreamDEX rejects an immediate order.
  /// @param pool Pool that rejected the order.
  /// @param orderType Immediate order type requested.
  error OrderRejected(address pool, uint8 orderType);

  /// @notice Raised when an immediate order unexpectedly returns a resting identifier.
  /// @param orderId Unexpected DreamDEX order identifier.
  error RestingOrder(uint128 orderId);

  /// @notice Raised when actual execution receives too few outcome shares.
  /// @param received Actual outcome shares received.
  /// @param minimum Minimum outcome shares authorized by the user.
  error InsufficientSharesOut(uint256 received, uint256 minimum);

  /// @notice Raised when actual execution spends too much collateral.
  /// @param spent Actual collateral spent.
  /// @param maximum Maximum collateral authorized by the user.
  error ExcessiveCollateralIn(uint256 spent, uint256 maximum);

  /// @notice Raised when an external balance delta contradicts the returned result.
  /// @param asset Asset or outcome-token contract reconciled.
  /// @param expected Nominal amount returned by the integration.
  /// @param actual Balance-derived amount.
  error BalanceDeltaMismatch(address asset, uint256 expected, uint256 actual);

  /// @notice Raised when an exact-ID outcome-token approval reports failure.
  /// @param token ERC-6909 outcome-token contract.
  /// @param spender Pinned DreamDEX pool.
  /// @param outcomeId Exact outcome ID whose approval failed.
  error TokenApprovalFailed(address token, address spender, uint256 outcomeId);

  /// @notice Raised when a temporary ERC-6909 operator change reports failure.
  /// @param token ERC-6909 outcome-token contract.
  /// @param operator Pinned settlement contract.
  /// @param approved Requested operator state.
  error TokenOperatorApprovalFailed(address token, address operator, bool approved);

  /// @notice Raised when an owner has not granted enough exact-ID outcome allowance.
  /// @param token ERC-6909 outcome-token contract.
  /// @param outcomeId Exact outcome ID required.
  /// @param available Exact-ID allowance currently available.
  /// @param required Outcome quantity requested.
  error InsufficientOutcomeAllowance(
    address token, uint256 outcomeId, uint256 available, uint256 required
  );

  /// @notice Raised when an oracle generation lacks a mature observation window.
  /// @param generationKey Generation being valued.
  /// @param age Current observation-window age in seconds.
  /// @param minimumAge Required minimum age in seconds.
  error OracleNotReady(bytes32 generationKey, uint256 age, uint256 minimumAge);

  /// @notice Raised when the newest oracle observation is stale.
  /// @param generationKey Generation being valued.
  /// @param age Age of the newest observation in seconds.
  /// @param maximumAge Largest permitted age in seconds.
  error StaleOracle(bytes32 generationKey, uint256 age, uint256 maximumAge);

  /// @notice Raised when an observation is submitted before the update interval.
  /// @param elapsed Seconds since the prior observation.
  /// @param minimumInterval Required interval in seconds.
  error ObservationTooSoon(uint256 elapsed, uint256 minimumInterval);

  /// @notice Raised when an oracle generation was already configured immutably.
  /// @param generationKey Existing generation identifier.
  error GenerationAlreadyConfigured(bytes32 generationKey);

  /// @notice Raised when the bounded visible book cannot cover configured observation size.
  /// @param generationKey Generation being sampled.
  /// @param filledQuantity Quantity covered by visible valid levels.
  /// @param requiredQuantity Configured observation quantity.
  error InsufficientBookDepth(
    bytes32 generationKey, uint256 filledQuantity, uint256 requiredQuantity
  );

  /// @notice Raised when top-of-book prices are crossed or a level violates binary price bounds.
  /// @param pool Pool whose book is invalid.
  /// @param bidPrice Current or offending bid price.
  /// @param askPrice Current or offending ask price.
  error InvalidBook(address pool, uint256 bidPrice, uint256 askPrice);

  /// @notice Raised when risk-increasing valuation is requested at or after market expiry.
  /// @param expiry Market expiry timestamp.
  /// @param currentTime Current timestamp.
  error MarketExpired(uint256 expiry, uint256 currentTime);

  /// @notice Raised when a risk increase would cross a configured debt ceiling.
  /// @param scope Identifier of the cap scope.
  /// @param resultingDebt Debt after the requested change.
  /// @param maximumDebt Configured ceiling.
  error DebtCapExceeded(bytes32 scope, uint256 resultingDebt, uint256 maximumDebt);

  /// @notice Raised when a risk increase would cross the vault utilization cap.
  /// @param resultingUtilization Resulting utilization in basis points.
  /// @param maximumUtilization Configured maximum utilization in basis points.
  error UtilizationExceeded(uint256 resultingUtilization, uint256 maximumUtilization);

  /// @notice Raised when opening is attempted inside a generation's no-borrow window.
  /// @param expiry Market trading expiry in seconds.
  /// @param currentTime Current timestamp in seconds.
  /// @param openingCutoff Required seconds remaining before expiry.
  error OpeningCutoffReached(uint256 expiry, uint256 currentTime, uint256 openingCutoff);

  /// @notice Raised when an opened position exceeds its share of observed executable depth.
  /// @param resultingShares Total position outcome shares after execution.
  /// @param maximumShares Maximum admitted shares derived from oracle depth.
  error PositionDepthExceeded(uint256 resultingShares, uint256 maximumShares);

  /// @notice Raised when a position action requests more attributed outcome shares than available.
  /// @param available Position shares before the action.
  /// @param required Shares requested by the action.
  error InsufficientPositionShares(uint256 available, uint256 required);

  /// @notice Raised when an attempted close leaves debt shares or outcome collateral behind.
  /// @param remainingShares Outcome shares left after attempted execution.
  /// @param remainingDebtShares Debt shares left after attempted repayment.
  error IncompleteClose(uint256 remainingShares, uint256 remainingDebtShares);

  /// @notice Raised when ordinary liquidation is attempted at or above required maintenance.
  /// @param positionId Position tested.
  /// @param ltvBps Current conservative loan-to-value ratio.
  /// @param maintenanceLtvBps Current expiry-compressed liquidation boundary.
  error PositionNotLiquidatable(uint256 positionId, uint256 ltvBps, uint256 maintenanceLtvBps);

  /// @notice Raised when conservative collateral value does not support required health.
  /// @param value Conservative collateral value in raw collateral units.
  /// @param requiredValue Required value in raw collateral units.
  error InsufficientHealth(uint256 value, uint256 requiredValue);

  /// @notice Raised when vault cash cannot satisfy an asset movement.
  /// @param available Available internal cash in raw collateral units.
  /// @param required Required raw collateral amount.
  error InsufficientLiquidity(uint256 available, uint256 required);

  /// @notice Raised when an account lacks sufficient vault shares.
  /// @param available Available vault shares.
  /// @param required Required vault shares.
  error InsufficientVaultShares(uint256 available, uint256 required);

  /// @notice Raised when delegated vault-share movement exceeds its allowance.
  /// @param available Available share allowance.
  /// @param required Required share allowance.
  error InsufficientShareAllowance(uint256 available, uint256 required);

  /// @notice Raised when a debt-share reduction exceeds total outstanding debt shares.
  /// @param available Outstanding debt shares before the reduction.
  /// @param required Debt shares requested for repayment or write-off.
  error InsufficientDebtShares(uint256 available, uint256 required);

  /// @notice Raised when exact debt repayment exceeds the controller's asset limit.
  /// @param required Assets required to retire the requested debt shares.
  /// @param maximum Maximum assets authorized by the controller.
  error RepaymentLimitExceeded(uint256 required, uint256 maximum);

  /// @notice Raised when a non-controller attempts to mutate vault debt.
  /// @param caller Unauthorized caller.
  /// @param controller Authorized controller.
  error NotController(address caller, address controller);

  /// @notice Raised when a non-configurator attempts to mutate oracle policy.
  /// @param caller Unauthorized caller.
  /// @param configurator Authorized immutable configurator.
  error NotConfigurator(address caller, address configurator);

  /// @notice Raised when a terminal action is requested before settlement finalization.
  /// @param outcomeId Outcome ID without a frozen terminal record.
  error SettlementNotFinal(uint256 outcomeId);

  /// @notice Raised when the same receivable would be written off more than once.
  /// @param positionId Position whose loss was already finalized.
  error LossAlreadyRecognized(uint256 positionId);

  /// @notice Raised when a recovery exceeds cumulative loss not already recovered.
  /// @param available Unrecovered cumulative bad debt.
  /// @param requested Recovery assets supplied by the caller.
  error RecoveryExceedsLoss(uint256 available, uint256 requested);

  /// @notice Raised when reserve release is attempted while debt or unrecovered loss remains.
  /// @param debtShares Outstanding vault debt shares.
  /// @param unrecoveredLoss Realized bad debt not yet recovered.
  error ReserveWithdrawalBlocked(uint256 debtShares, uint256 unrecoveredLoss);

  /// @notice Raised when a delayed change is executed before its activation time.
  /// @param changeId Identifier of the pending change.
  /// @param executableAt Earliest execution timestamp.
  /// @param currentTime Current timestamp.
  error ChangeNotReady(bytes32 changeId, uint256 executableAt, uint256 currentTime);

  /// @notice Raised when a delayed change identifier has no pending record.
  /// @param changeId Missing change identifier.
  error ChangeNotScheduled(bytes32 changeId);

  /// @notice Raised when a pending delayed-change identifier is reused.
  /// @param changeId Existing pending identifier.
  error ChangeAlreadyScheduled(bytes32 changeId);

  /// @notice Raised when supplied delayed-change calldata does not match its commitment.
  /// @param expectedHash Hash committed when the change was scheduled.
  /// @param actualHash Hash of the supplied execution payload.
  error ChangePayloadMismatch(bytes32 expectedHash, bytes32 actualHash);

  /// @notice Raised when an emergency actor attempts to loosen protocol restrictions.
  /// @param currentMode Current protocol mode.
  /// @param requestedMode Requested less-restrictive mode.
  error UnsafeModeTransition(uint8 currentMode, uint8 requestedMode);
}
