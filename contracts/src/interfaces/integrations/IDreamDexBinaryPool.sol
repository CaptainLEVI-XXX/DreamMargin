// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary pool integration interface
/// @author DreamMargin contributors
/// @notice Exposes the exact binary-pool reads and writes used by DreamMargin.
/// @dev Prices are always YES-side prices. Order kinds and order types are
///      selector-critical uint8 values validated by the adapter.
interface IDreamDexBinaryPool {
  /// @notice One aggregated order-book level.
  /// @param price YES-side price in the pool's raw price unit.
  /// @param quantity Aggregate outcome quantity at the price.
  struct BookLevel {
    uint256 price;
    uint256 quantity;
  }

  /// @notice Order-book grid and minimum-size parameters.
  /// @param tickSize Valid price increment in raw price units.
  /// @param minQuantity Smallest accepted order quantity.
  /// @param lotSize Valid quantity increment.
  struct OrderBookParameters {
    uint256 tickSize;
    uint256 minQuantity;
    uint256 lotSize;
  }

  /// @notice One active order stored by the DreamDEX order book.
  /// @param orderId Pool-scoped order identifier.
  /// @param isBid Whether the order buys its selected outcome.
  /// @param owner Account that placed the order.
  /// @param userData Opaque caller data recorded on the order.
  /// @param price YES-side limit price in raw pool units.
  /// @param fullQuantity Original outcome quantity.
  /// @param quantityRemaining Unfilled quantity still resting on the book.
  /// @param expireTimestampNs Order expiry in nanoseconds.
  struct Order {
    uint128 orderId;
    bool isBid;
    address owner;
    uint64 userData;
    uint256 price;
    uint256 fullQuantity;
    uint256 quantityRemaining;
    uint64 expireTimestampNs;
  }

  /// @notice Current market generation bound to a recyclable binary pool.
  /// @param collateralToken Collateral token used for settlement and trades.
  /// @param market Binary market state contract.
  /// @param outcomeToken Shared ERC-6909 outcome-token contract.
  /// @param yesId ERC-6909 ID for the current YES outcome.
  /// @param noId ERC-6909 ID for the current NO outcome.
  /// @param oneCollateral One whole collateral token in raw units.
  /// @param setBacking Total live collateral backing all outstanding complete sets.
  /// @param feeRecipient Account receiving venue fees.
  /// @param makerFeeBpsTimes1k Maker fee in basis points times one thousand.
  /// @param takerFeeBpsTimes1k Taker fee in basis points times one thousand.
  /// @param maxBuilderFeeBpsTimes1k Maximum builder fee in basis points times one thousand.
  /// @param settlementFeeBpsTimes1k Settlement fee in basis points times one thousand.
  /// @param settlement Permanent binary settlement contract.
  /// @param marketNonce Current recyclable-pool generation nonce.
  /// @param finalized Whether the current generation has been finalized.
  struct BinaryPoolInfo {
    address collateralToken;
    address market;
    address outcomeToken;
    uint256 yesId;
    uint256 noId;
    uint256 oneCollateral;
    uint256 setBacking;
    address feeRecipient;
    uint256 makerFeeBpsTimes1k;
    uint256 takerFeeBpsTimes1k;
    uint256 maxBuilderFeeBpsTimes1k;
    uint256 settlementFeeBpsTimes1k;
    address settlement;
    uint64 marketNonce;
    bool finalized;
  }

  /// @notice Returns aggregated levels from one side of the current book.
  /// @param isBid True for bids and false for asks.
  /// @param numLevels Maximum number of price levels returned.
  /// @return levels Ordered price levels; an empty book returns an empty array.
  function getBookLevels(bool isBid, uint64 numLevels)
    external
    view
    returns (BookLevel[] memory levels);

  /// @notice Returns the current order-book grid.
  /// @return parameters Tick, minimum quantity, and lot-size values.
  function getOrderBookParameters() external view returns (OrderBookParameters memory parameters);

  /// @notice Returns an active order or reverts with `IncorrectOrder()` when absent.
  /// @param orderId Pool-scoped order identifier.
  /// @return order Active order state.
  function getOrder(uint128 orderId) external view returns (Order memory order);

  /// @notice Returns the latest permitted order expiry in nanoseconds.
  /// @return expiryTimestampNs Pool order-expiry ceiling in nanoseconds.
  function marketExpiryNs() external view returns (uint64 expiryTimestampNs);

  /// @notice Returns the complete current pool-generation binding.
  /// @return info Current binary pool information.
  function getBinaryPoolParams() external view returns (BinaryPoolInfo memory info);

  /// @notice Places one explicit YES/NO binary order.
  /// @param kind Binary order kind: buy/sell YES or buy/sell NO.
  /// @param price YES-side limit price in raw pool units.
  /// @param quantity Outcome quantity, quantized to the pool lot size.
  /// @param expireTimestampNs Order expiry in nanoseconds.
  /// @param orderType DreamDEX order type; DreamMargin permits only FOK or IOC.
  /// @param selfMatchingOption DreamDEX self-match behavior.
  /// @param builder Optional builder address, zero for no builder.
  /// @param builderFeeBpsTimes1k Builder fee in basis points times one thousand.
  /// @param userData Opaque caller data recorded on the order.
  /// @return success Whether the venue accepted and executed the order.
  /// @return id Venue order ID; filled and cancelled immediate orders also receive IDs.
  function placeBinaryOrder(
    uint8 kind,
    uint256 price,
    uint256 quantity,
    uint64 expireTimestampNs,
    uint8 orderType,
    uint8 selfMatchingOption,
    address builder,
    uint96 builderFeeBpsTimes1k,
    uint64 userData
  ) external payable returns (bool success, uint128 id);

  /// @notice Mints one complete YES/NO set from collateral.
  /// @param yesTo Account receiving the YES outcome.
  /// @param noTo Account receiving the NO outcome.
  /// @param amount Complete-set amount in outcome-token units.
  function mintSet(address yesTo, address noTo, uint256 amount) external;

  /// @notice Burns equal YES and NO amounts for collateral.
  /// @param amount Complete-set amount in outcome-token units.
  function burnSet(uint256 amount) external;
}
