// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary-market adapter
/// @author DreamMargin contributors
/// @notice Normalizes generation validation and immediate YES/NO execution for DreamMargin.
/// @dev This abstract layer declares no storage. Its caller supplies the statically bound module.

import {IDreamDexBinaryMarket} from "src/interfaces/integrations/IDreamDexBinaryMarket.sol";
import {IDreamDexBinaryModule} from "src/interfaces/integrations/IDreamDexBinaryModule.sol";
import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {LibDreamMarginConstants} from "src/libs/dreammargin/LibDreamMarginConstants.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";
import {BookWalk, LibPositionRisk, RiskBookLevel} from "src/libs/dreammargin/LibPositionRisk.sol";

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Stateless internal DreamDEX integration composed into the controller.
abstract contract DreamDexAdapter {
  using SafeTransferLib for address;

  /// @notice Canonical module record fields required for generation validation.
  /// @param oracleQuestionId Oracle question bound to the market.
  /// @param outcomeSlotCount Number of outcome slots.
  /// @param voidPolicy Market void policy.
  /// @param collateral Collateral token recorded by the module.
  /// @param originOperatorId Originating operator identifier.
  /// @param originVenueId Originating venue identifier.
  /// @param oracleAdapter Oracle adapter address.
  /// @param creator Market creator address.
  /// @param market Binary market state contract.
  /// @param pool Recyclable pool address.
  /// @param yesId YES outcome ID.
  /// @param noId NO outcome ID.
  /// @param tradingStart Trading-start timestamp in seconds.
  /// @param expiry Trading expiry in seconds.
  struct ModuleMarket {
    uint256 oracleQuestionId;
    uint8 outcomeSlotCount;
    uint8 voidPolicy;
    address collateral;
    uint32 originOperatorId;
    bytes32 originVenueId;
    address oracleAdapter;
    address creator;
    address market;
    address pool;
    uint256 yesId;
    uint256 noId;
    uint64 tradingStart;
    uint64 expiry;
  }

  /// @notice Fully validated deployed state for one exact generation outcome.
  /// @param market Binary market state contract.
  /// @param settlement Permanent settlement contract.
  /// @param oppositeId Opposite outcome ID used for complete-set recovery.
  /// @param oneCollateral One whole collateral token in raw units.
  /// @param expiry Trading expiry in seconds.
  /// @param orderExpiryNs Maximum pool order expiry in nanoseconds.
  /// @param orderBook Tick, minimum quantity, and lot-size constraints.
  struct ValidatedGeneration {
    address market;
    address settlement;
    uint256 oppositeId;
    uint256 oneCollateral;
    uint64 expiry;
    uint64 orderExpiryNs;
    IDreamDexBinaryPool.OrderBookParameters orderBook;
  }

  /// @notice User-bounded immediate binary-order request.
  /// @param key Exact pinned DreamDEX generation and outcome.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param price YES-side limit price in raw pool units.
  /// @param quantity Maximum outcome quantity offered or requested.
  /// @param minimumOutput Minimum received shares for buys or collateral for sells.
  /// @param maximumInput Maximum collateral spent for buys; ignored for sells.
  /// @param deadline Latest execution timestamp in seconds.
  /// @param orderType FOK or IOC DreamDEX order type.
  /// @param userData Opaque controller attribution data sent to DreamDEX.
  struct ImmediateOrder {
    MarketKey key;
    uint8 outcomeIndex;
    uint256 price;
    uint256 quantity;
    uint256 minimumOutput;
    uint256 maximumInput;
    uint256 deadline;
    uint8 orderType;
    uint64 userData;
  }

  /// @notice Actual balance-derived result of one immediate order.
  /// @param outcomeAmount Shares received by a buy or spent by a sell.
  /// @param collateralAmount Collateral spent by a buy or received by a sell.
  struct ExecutionResult {
    uint256 outcomeAmount;
    uint256 collateralAmount;
  }

  /// @notice Canonical normalized book walks used by oracle and liquidation valuation.
  /// @param bestBid Best executable same-outcome bid.
  /// @param oneCollateral One whole collateral token in pool native units.
  /// @param direct Same-outcome descending bid walk.
  /// @param opposite Opposite-outcome ascending ask walk.
  struct RecoveryBook {
    uint256 bestBid;
    uint256 oneCollateral;
    BookWalk direct;
    BookWalk opposite;
  }

  // -------------------------------------------------------------------------
  // Generation validation
  // -------------------------------------------------------------------------

  /// @notice Validates every module, pool, and market field in a pinned generation tuple.
  /// @dev The caller supplies an immutable module binding. This read performs no state changes.
  /// @param module_ Statically bound DreamDEX binary module.
  /// @param key Exact registered market-generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param requireTrading Whether the authoritative market status must be Trading.
  /// @return generation Normalized current generation state.
  function _validateGeneration(
    address module_,
    MarketKey memory key,
    uint8 outcomeIndex,
    bool requireTrading
  ) internal view returns (ValidatedGeneration memory generation) {
    if (outcomeIndex > 1) {
      revert LibDreamMarginErrors.ValueOutOfBounds("OUTCOME_INDEX", outcomeIndex, 1);
    }

    uint64 moduleNonce = IDreamDexBinaryModule(module_).marketNonce(key.marketId);
    if (moduleNonce != key.marketNonce) {
      revert LibDreamMarginErrors.PoolRecycled(key.pool, key.marketNonce, moduleNonce);
    }

    ModuleMarket memory moduleMarket = _readModuleMarket(module_, key.marketId);
    _equalAddress("MODULE_POOL", key.pool, moduleMarket.pool);
    _equalAddress("MODULE_COLLATERAL", key.collateral, moduleMarket.collateral);
    uint256 expectedOutcomeId = outcomeIndex == 0 ? moduleMarket.yesId : moduleMarket.noId;
    _equalUint("MODULE_OUTCOME_ID", key.outcomeId, expectedOutcomeId);

    IDreamDexBinaryPool pool = IDreamDexBinaryPool(key.pool);
    IDreamDexBinaryPool.BinaryPoolInfo memory info = pool.getBinaryPoolParams();
    _equalAddress("POOL_MARKET", moduleMarket.market, info.market);
    _equalAddress("POOL_COLLATERAL", key.collateral, info.collateralToken);
    _equalAddress("POOL_OUTCOME_TOKEN", key.outcomeToken, info.outcomeToken);
    _equalUint("POOL_YES_ID", moduleMarket.yesId, info.yesId);
    _equalUint("POOL_NO_ID", moduleMarket.noId, info.noId);
    _equalUint("POOL_NONCE", key.marketNonce, info.marketNonce);
    if (info.finalized) _mismatch("POOL_FINALIZED", bytes32(0), bytes32(uint256(1)));
    if (info.oneCollateral == 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("ONE_COLLATERAL", 0, type(uint256).max);
    }

    address settlement = IDreamDexBinaryModule(module_).settlement();
    _equalAddress("POOL_SETTLEMENT", settlement, info.settlement);

    IDreamDexBinaryMarket market = IDreamDexBinaryMarket(moduleMarket.market);
    _equalAddress("MARKET_POOL", key.pool, market.pool());
    _equalAddress("MARKET_COLLATERAL", key.collateral, market.collateral());
    _equalAddress("MARKET_OUTCOME_TOKEN", key.outcomeToken, market.outcomeToken());
    _equalUint("MARKET_YES_ID", moduleMarket.yesId, market.yesId());
    _equalUint("MARKET_NO_ID", moduleMarket.noId, market.noId());
    _equalUint("MARKET_EXPIRY", moduleMarket.expiry, market.expiry());

    uint8 status = market.status();
    if (requireTrading && status != LibDreamMarginConstants.MARKET_STATUS_TRADING) {
      revert LibDreamMarginErrors.InvalidMarketStatus(
        moduleMarket.market, status, LibDreamMarginConstants.MARKET_STATUS_TRADING
      );
    }

    IDreamDexBinaryPool.OrderBookParameters memory orderBook = pool.getOrderBookParameters();
    if (orderBook.tickSize == 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("TICK_SIZE", 0, type(uint256).max);
    }
    if (orderBook.lotSize == 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("LOT_SIZE", 0, type(uint256).max);
    }

    generation = ValidatedGeneration({
      market: moduleMarket.market,
      settlement: settlement,
      oppositeId: outcomeIndex == 0 ? moduleMarket.noId : moduleMarket.yesId,
      oneCollateral: info.oneCollateral,
      expiry: moduleMarket.expiry,
      orderExpiryNs: pool.marketExpiryNs(),
      orderBook: orderBook
    });
  }

  /// @notice Reads and normalizes one binary book into same-side bids and opposite-side asks.
  /// @param key Exact pinned generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param quantity Outcome quantity walked through both recovery routes.
  /// @param maxBookLevels Maximum external levels read from each raw side.
  /// @return book Canonical route walks and pool economics.
  function _walkRecoveryBook(
    MarketKey memory key,
    uint8 outcomeIndex,
    uint256 quantity,
    uint16 maxBookLevels
  ) internal view returns (RecoveryBook memory book) {
    if (outcomeIndex > 1) {
      revert LibDreamMarginErrors.ValueOutOfBounds("OUTCOME_INDEX", outcomeIndex, 1);
    }
    IDreamDexBinaryPool pool = IDreamDexBinaryPool(key.pool);
    IDreamDexBinaryPool.BinaryPoolInfo memory info = pool.getBinaryPoolParams();
    if (info.oneCollateral == 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("ONE_COLLATERAL", 0, type(uint256).max);
    }
    if (info.setBacking == 0) {
      revert LibDreamMarginErrors.ValueOutOfBounds("SET_BACKING", 0, type(uint256).max);
    }
    IDreamDexBinaryPool.BookLevel[] memory bids = pool.getBookLevels(true, maxBookLevels);
    IDreamDexBinaryPool.BookLevel[] memory asks = pool.getBookLevels(false, maxBookLevels);
    if (bids.length != 0 && asks.length != 0 && bids[0].price >= asks[0].price) {
      revert LibDreamMarginErrors.InvalidBook(key.pool, bids[0].price, asks[0].price);
    }

    IDreamDexBinaryPool.BookLevel[] memory source = outcomeIndex == 0 ? bids : asks;
    bool invert = outcomeIndex == 1;
    RiskBookLevel[] memory direct =
      _transformRecoveryLevels(source, info.oneCollateral, invert, true, key.pool);
    RiskBookLevel[] memory opposite =
      _transformRecoveryLevels(source, info.oneCollateral, !invert, false, key.pool);
    book = RecoveryBook({
      bestBid: direct.length == 0 ? 0 : direct[0].price,
      oneCollateral: info.oneCollateral,
      direct: LibPositionRisk.walkBidsDown(direct, quantity, info.oneCollateral),
      opposite: LibPositionRisk.walkAsksUp(opposite, quantity, info.oneCollateral)
    });
  }

  /// @notice Converts one raw YES side into strictly ordered normalized outcome prices.
  /// @param levels Raw pool levels.
  /// @param oneCollateral Exclusive price ceiling.
  /// @param invert Whether prices become `oneCollateral - price`.
  /// @param descending Whether normalized prices must be nonincreasing.
  /// @param pool Pool used in malformed-book errors.
  /// @return transformed Normalized levels preserving quantities.
  function _transformRecoveryLevels(
    IDreamDexBinaryPool.BookLevel[] memory levels,
    uint256 oneCollateral,
    bool invert,
    bool descending,
    address pool
  ) private pure returns (RiskBookLevel[] memory transformed) {
    uint256 length = levels.length;
    transformed = new RiskBookLevel[](length);
    uint256 previous = 0;
    // Every bounded external book level fails closed at the first malformed value.
    // forge-lint: disable-start(require-revert-in-loop)
    for (uint256 i = 0; i < length; ++i) {
      uint256 rawPrice = levels[i].price;
      uint256 quantity = levels[i].quantity;
      if (rawPrice == 0 || rawPrice >= oneCollateral || quantity == 0) {
        revert LibDreamMarginErrors.InvalidBook(pool, rawPrice, rawPrice);
      }
      uint256 price = invert ? oneCollateral - rawPrice : rawPrice;
      if (i != 0 && ((descending && price > previous) || (!descending && price < previous))) {
        revert LibDreamMarginErrors.InvalidBook(pool, previous, price);
      }
      transformed[i] = RiskBookLevel({price: price, quantity: quantity});
      previous = price;
    }
    // forge-lint: disable-end(require-revert-in-loop)
  }

  // -------------------------------------------------------------------------
  // Immediate execution
  // -------------------------------------------------------------------------

  /// @notice Buys one exact outcome through IOC or FOK and trusts only balance deltas.
  /// @dev The caller must already custody enough collateral. The exact pool approval is reset.
  /// @param module_ Statically bound DreamDEX binary module.
  /// @param order User-authorized generation, quantity, price, fill, spend, and deadline bounds.
  /// @return result Actual outcome received and collateral spent.
  function _buyOutcome(address module_, ImmediateOrder memory order)
    internal
    returns (ExecutionResult memory result)
  {
    ValidatedGeneration memory generation =
      _validateGeneration(module_, order.key, order.outcomeIndex, true);
    uint64 deadlineNs = _validateOrder(order, generation);

    uint256 collateralBefore = IERC20Minimal(order.key.collateral).balanceOf(address(this));
    uint256 outcomeBefore =
      IERC6909(order.key.outcomeToken).balanceOf(address(this), order.key.outcomeId);
    order.key.collateral.safeApproveWithRetry(order.key.pool, order.maximumInput);

    uint8 kind = order.outcomeIndex == 0
      ? LibDreamMarginConstants.ORDER_KIND_BUY_YES
      : LibDreamMarginConstants.ORDER_KIND_BUY_NO;
    (bool success, uint128 orderId) = _place(order, kind, deadlineNs);
    order.key.collateral.safeApproveWithRetry(order.key.pool, 0);
    _requireImmediateSuccess(order.key.pool, order.orderType, success, orderId);

    uint256 collateralAfter = IERC20Minimal(order.key.collateral).balanceOf(address(this));
    uint256 outcomeAfter =
      IERC6909(order.key.outcomeToken).balanceOf(address(this), order.key.outcomeId);
    if (collateralAfter > collateralBefore || outcomeAfter < outcomeBefore) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        order.key.outcomeToken, outcomeBefore, outcomeAfter
      );
    }

    result.outcomeAmount = outcomeAfter - outcomeBefore;
    result.collateralAmount = collateralBefore - collateralAfter;
    if (result.outcomeAmount < order.minimumOutput) {
      revert LibDreamMarginErrors.InsufficientSharesOut(result.outcomeAmount, order.minimumOutput);
    }
    if (result.collateralAmount > order.maximumInput) {
      revert LibDreamMarginErrors.ExcessiveCollateralIn(result.collateralAmount, order.maximumInput);
    }
  }

  /// @notice Sells one exact outcome through IOC or FOK and trusts only balance deltas.
  /// @dev The exact-ID pool allowance is limited to quantity and reset after execution.
  /// @param module_ Statically bound DreamDEX binary module.
  /// @param order User-authorized generation, quantity, price, proceeds, and deadline bounds.
  /// @return result Actual outcome spent and collateral received.
  function _sellOutcome(address module_, ImmediateOrder memory order)
    internal
    returns (ExecutionResult memory result)
  {
    ValidatedGeneration memory generation =
      _validateGeneration(module_, order.key, order.outcomeIndex, true);
    uint64 deadlineNs = _validateOrder(order, generation);

    IERC6909 outcome = IERC6909(order.key.outcomeToken);
    uint256 collateralBefore = IERC20Minimal(order.key.collateral).balanceOf(address(this));
    uint256 outcomeBefore = outcome.balanceOf(address(this), order.key.outcomeId);
    if (!outcome.approve(order.key.pool, order.key.outcomeId, order.quantity)) {
      revert LibDreamMarginErrors.TokenApprovalFailed(
        order.key.outcomeToken, order.key.pool, order.key.outcomeId
      );
    }

    uint8 kind = order.outcomeIndex == 0
      ? LibDreamMarginConstants.ORDER_KIND_SELL_YES
      : LibDreamMarginConstants.ORDER_KIND_SELL_NO;
    (bool success, uint128 orderId) = _place(order, kind, deadlineNs);
    if (!outcome.approve(order.key.pool, order.key.outcomeId, 0)) {
      revert LibDreamMarginErrors.TokenApprovalFailed(
        order.key.outcomeToken, order.key.pool, order.key.outcomeId
      );
    }
    _requireImmediateSuccess(order.key.pool, order.orderType, success, orderId);

    uint256 collateralAfter = IERC20Minimal(order.key.collateral).balanceOf(address(this));
    uint256 outcomeAfter = outcome.balanceOf(address(this), order.key.outcomeId);
    if (collateralAfter < collateralBefore || outcomeAfter > outcomeBefore) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        order.key.outcomeToken, outcomeBefore, outcomeAfter
      );
    }

    result.outcomeAmount = outcomeBefore - outcomeAfter;
    result.collateralAmount = collateralAfter - collateralBefore;
    if (result.outcomeAmount > order.quantity) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        order.key.outcomeToken, order.quantity, result.outcomeAmount
      );
    }
    if (result.collateralAmount < order.minimumOutput) {
      revert LibDreamMarginErrors.BalanceDeltaMismatch(
        order.key.collateral, order.minimumOutput, result.collateralAmount
      );
    }
  }

  /// @notice Validates immediate-order type, grid, price domain, and nanosecond deadline.
  /// @param order User-bounded immediate order.
  /// @param generation Validated current pool generation.
  /// @return deadlineNs Deadline converted to nanoseconds without truncation.
  function _validateOrder(ImmediateOrder memory order, ValidatedGeneration memory generation)
    private
    view
    returns (uint64 deadlineNs)
  {
    if (
      order.orderType != LibDreamMarginConstants.ORDER_TYPE_FOK
        && order.orderType != LibDreamMarginConstants.ORDER_TYPE_IOC
    ) revert LibDreamMarginErrors.UnsupportedOrderType(order.orderType);
    // Timestamp deadlines are the intended user replay and stale-quote boundary.
    // forge-lint: disable-next-line(block-timestamp)
    if (order.deadline <= block.timestamp) {
      revert LibDreamMarginErrors.DeadlineExpired(order.deadline, block.timestamp);
    }
    uint256 maximumDeadline = type(uint64).max / LibDreamMarginConstants.NS_PER_SECOND;
    if (order.deadline > maximumDeadline) {
      revert LibDreamMarginErrors.ValueOutOfBounds("DEADLINE", order.deadline, maximumDeadline);
    }
    uint256 deadlineNs256 = order.deadline * LibDreamMarginConstants.NS_PER_SECOND;
    if (deadlineNs256 > generation.orderExpiryNs) {
      revert LibDreamMarginErrors.OrderDeadlineExceeded(deadlineNs256, generation.orderExpiryNs);
    }
    // The explicit maximumDeadline check proves the nanosecond value fits uint64.
    // forge-lint: disable-next-line(unsafe-typecast)
    deadlineNs = uint64(deadlineNs256);

    if (
      order.price == 0 || order.price >= generation.oneCollateral
        || order.price % generation.orderBook.tickSize != 0
    ) revert LibDreamMarginErrors.InvalidTick(order.price, generation.orderBook.tickSize);
    if (order.quantity < generation.orderBook.minQuantity) {
      revert LibDreamMarginErrors.QuantityBelowMinimum(
        order.quantity, generation.orderBook.minQuantity
      );
    }
    if (order.quantity % generation.orderBook.lotSize != 0) {
      revert LibDreamMarginErrors.InvalidLot(order.quantity, generation.orderBook.lotSize);
    }
  }

  /// @notice Calls the exact payable DreamDEX binary order selector with zero native value.
  /// @param order User-bounded immediate order.
  /// @param kind DreamDEX BUY/SELL YES/NO kind.
  /// @param deadlineNs Validated nanosecond deadline.
  /// @return success Venue acceptance and execution flag.
  /// @return orderId Returned order identifier, required to remain zero.
  function _place(ImmediateOrder memory order, uint8 kind, uint64 deadlineNs)
    private
    returns (bool success, uint128 orderId)
  {
    (success, orderId) = IDreamDexBinaryPool(order.key.pool)
      .placeBinaryOrder(
        kind,
        order.price,
        order.quantity,
        deadlineNs,
        order.orderType,
        0,
        address(0),
        0,
        order.userData
      );
  }

  /// @notice Rejects failed immediate execution or any returned resting-order identifier.
  /// @param pool Pool that returned the result.
  /// @param orderType Immediate order type requested.
  /// @param success Venue acceptance flag.
  /// @param orderId Returned order identifier.
  function _requireImmediateSuccess(address pool, uint8 orderType, bool success, uint128 orderId)
    private
    pure
  {
    if (!success) revert LibDreamMarginErrors.OrderRejected(pool, orderType);
    if (orderId != 0) revert LibDreamMarginErrors.RestingOrder(orderId);
  }

  // -------------------------------------------------------------------------
  // Read normalization
  // -------------------------------------------------------------------------

  /// @notice Reads only module-record fields required by DreamMargin.
  /// @param module_ Statically bound binary module.
  /// @param marketId DreamDEX market identifier.
  /// @return record Normalized market record.
  function _readModuleMarket(address module_, bytes32 marketId)
    private
    view
    returns (ModuleMarket memory record)
  {
    (
      record.oracleQuestionId,
      record.outcomeSlotCount,
      record.voidPolicy,
      record.collateral,
      record.originOperatorId,
      record.originVenueId,
      record.oracleAdapter,
      record.creator,
      record.market,
      record.pool,
      record.yesId,
      record.noId,
      record.tradingStart,
      record.expiry
    ) = IDreamDexBinaryModule(module_).markets(marketId);
  }

  /// @notice Reverts when two integration addresses differ.
  /// @param field Identifier of the compared field.
  /// @param expected Pinned expected address.
  /// @param actual Address returned by DreamDEX.
  function _equalAddress(bytes32 field, address expected, address actual) private pure {
    if (expected != actual) {
      _mismatch(field, bytes32(uint256(uint160(expected))), bytes32(uint256(uint160(actual))));
    }
  }

  /// @notice Reverts when two integration integers differ.
  /// @param field Identifier of the compared field.
  /// @param expected Pinned expected integer.
  /// @param actual Integer returned by DreamDEX.
  function _equalUint(bytes32 field, uint256 expected, uint256 actual) private pure {
    if (expected != actual) _mismatch(field, bytes32(expected), bytes32(actual));
  }

  /// @notice Reverts with a normalized integration mismatch.
  /// @param field Identifier of the compared field.
  /// @param expected Pinned expected value.
  /// @param actual Value returned by DreamDEX.
  function _mismatch(bytes32 field, bytes32 expected, bytes32 actual) private pure {
    revert LibDreamMarginErrors.IntegrationValueMismatch(field, expected, actual);
  }
}
