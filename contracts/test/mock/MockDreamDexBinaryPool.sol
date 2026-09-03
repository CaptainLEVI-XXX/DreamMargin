// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary pool test model
/// @author DreamMargin contributors
/// @notice Models recyclable generation bindings and immediate binary fills.
/// @dev The model deliberately exposes fill and returned-order-ID controls so
///      adapter tests can cover partial IOC fills, failed FOK orders, and an
///      invalid resting-order response.

import {IDreamDexBinaryPool} from "src/interfaces/integrations/IDreamDexBinaryPool.sol";
import {IERC20Minimal} from "src/interfaces/integrations/IERC20Minimal.sol";
import {IERC6909} from "src/interfaces/integrations/IERC6909.sol";

import {MockERC6909} from "test/mock/MockERC6909.sol";

/// @notice Raised when a mock order violates the configured tick or lot grid.
/// @param price Submitted YES-side price.
/// @param quantity Submitted outcome quantity.
error MockDreamDexInvalidGrid(uint256 price, uint256 quantity);

/// @notice Raised when a mock order has an unsupported immediate order type.
/// @param orderType Submitted DreamDEX order type.
error MockDreamDexInvalidOrderType(uint8 orderType);

/// @notice Raised when a mock order uses an invalid deadline.
/// @param deadlineNs Submitted deadline in nanoseconds.
error MockDreamDexInvalidDeadline(uint64 deadlineNs);

/// @notice Raised when native value is sent to the collateral-token mock path.
/// @param value Native value sent with the order.
error MockDreamDexUnexpectedValue(uint256 value);

/// @notice Raised when a mock binary kind is outside the four deployed values.
/// @param kind Submitted binary order kind.
error MockDreamDexInvalidKind(uint8 kind);

/// @notice Raised when a mock token transfer reports failure.
error MockDreamDexTransferFailed();

/// @notice Raised when a builder fee is configured without a builder.
/// @param feeBpsTimes1k Submitted builder fee.
error MockDreamDexBuilderMissing(uint96 feeBpsTimes1k);

/// @notice Mirrors DreamDEX's absence signal for an inactive order ID.
error IncorrectOrder();

/// @notice Local DreamDEX binary-pool execution model.
/// @dev The payable selector matches DreamDEX, but every nonzero msg.value
///      reverts before acceptance, so the model cannot lock native value.
// forge-lint: disable-next-line(locked-ether)
contract MockDreamDexBinaryPool is IDreamDexBinaryPool {
  /// @notice Fill ratio denominator.
  uint256 private constant _BPS = 10_000;

  /// @notice Current recyclable pool binding.
  BinaryPoolInfo private _info;

  /// @notice Current tick, lot, and minimum quantity.
  OrderBookParameters private _orderBookParameters;

  /// @notice Current bid levels.
  BookLevel[] private _bids;

  /// @notice Current ask levels.
  BookLevel[] private _asks;

  /// @notice Pool order expiry ceiling in nanoseconds.
  uint64 public override marketExpiryNs;

  /// @notice Portion of an order filled by the next execution.
  uint256 public fillBps = _BPS;

  /// @notice Order ID returned after an immediate execution.
  uint128 public returnedOrderId;

  /// @notice Order ID exposed as active by `getOrder`, or zero when none is active.
  uint128 public activeOrderId;

  /// @notice Last submitted binary kind.
  uint8 public lastKind;

  /// @notice Last submitted YES-side price.
  uint256 public lastPrice;

  /// @notice Last submitted outcome quantity.
  uint256 public lastQuantity;

  /// @notice Last submitted nanosecond deadline.
  uint64 public lastDeadlineNs;

  /// @notice Timestamp at which the last valid order reached the venue model.
  uint256 public lastSubmittedAt;

  /// @notice Number of valid order submissions observed by the venue model.
  uint256 public submissionCount;

  /// @notice Last submitted immediate order type.
  uint8 public lastOrderType;

  /// @notice Last submitted self-match option.
  uint8 public lastSelfMatchingOption;

  /// @notice Last submitted builder.
  address public lastBuilder;

  /// @notice Last submitted builder fee.
  uint96 public lastBuilderFeeBpsTimes1k;

  /// @notice Last submitted user data.
  uint64 public lastUserData;

  /// @notice Creates a binary-pool generation model.
  /// @param info_ Initial generation binding.
  /// @param parameters_ Initial tick, lot, and minimum quantity.
  /// @param marketExpiryNs_ Initial order expiry ceiling in nanoseconds.
  constructor(
    BinaryPoolInfo memory info_,
    OrderBookParameters memory parameters_,
    uint64 marketExpiryNs_
  ) {
    _info = info_;
    _orderBookParameters = parameters_;
    marketExpiryNs = marketExpiryNs_;
  }

  /// @notice Rebinds the recyclable pool to another market generation.
  /// @param info_ Replacement generation binding.
  /// @param marketExpiryNs_ Replacement order expiry ceiling.
  function recycle(BinaryPoolInfo calldata info_, uint64 marketExpiryNs_) external {
    _info = info_;
    marketExpiryNs = marketExpiryNs_;
  }

  /// @notice Changes the next order's fill ratio and returned order ID.
  /// @param fillBps_ Filled portion in basis points.
  /// @param returnedOrderId_ Order ID returned by the mock.
  function setExecution(uint256 fillBps_, uint128 returnedOrderId_) external {
    fillBps = fillBps_;
    returnedOrderId = returnedOrderId_;
  }

  /// @notice Selects whether a returned ID remains active after execution.
  /// @param orderId_ Active order ID, or zero when no order rests.
  function setActiveOrder(uint128 orderId_) external {
    activeOrderId = orderId_;
  }

  /// @notice Replaces one side of the visible order book.
  /// @param isBid True to replace bids and false to replace asks.
  /// @param levels Replacement ordered levels.
  function setBookLevels(bool isBid, BookLevel[] calldata levels) external {
    uint256 length = levels.length;
    if (isBid) {
      delete _bids;
      for (uint256 i = 0; i < length; ++i) {
        _bids.push(levels[i]);
      }
    } else {
      delete _asks;
      for (uint256 i = 0; i < length; ++i) {
        _asks.push(levels[i]);
      }
    }
  }

  /// @inheritdoc IDreamDexBinaryPool
  function getBookLevels(bool isBid, uint64 numLevels)
    external
    view
    override
    returns (BookLevel[] memory levels)
  {
    BookLevel[] storage source = isBid ? _bids : _asks;
    uint256 sourceLength = source.length;
    uint256 length = sourceLength < numLevels ? sourceLength : numLevels;
    levels = new BookLevel[](length);
    for (uint256 i = 0; i < length; ++i) {
      levels[i] = source[i];
    }
  }

  /// @inheritdoc IDreamDexBinaryPool
  function getOrderBookParameters()
    external
    view
    override
    returns (OrderBookParameters memory parameters)
  {
    parameters = _orderBookParameters;
  }

  /// @inheritdoc IDreamDexBinaryPool
  function getOrder(uint128 orderId) external view override returns (Order memory order) {
    if (orderId == 0 || orderId != activeOrderId) revert IncorrectOrder();
    order = Order({
      orderId: orderId,
      isBid: true,
      owner: msg.sender,
      userData: lastUserData,
      price: lastPrice,
      fullQuantity: lastQuantity,
      quantityRemaining: lastQuantity,
      expireTimestampNs: lastDeadlineNs
    });
  }

  /// @inheritdoc IDreamDexBinaryPool
  function getBinaryPoolParams() external view override returns (BinaryPoolInfo memory info) {
    info = _info;
  }

  /// @inheritdoc IDreamDexBinaryPool
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
  ) external payable override returns (bool success, uint128 id) {
    if (msg.value != 0) revert MockDreamDexUnexpectedValue(msg.value);
    if (kind > 3) revert MockDreamDexInvalidKind(kind);
    if (orderType != 1 && orderType != 2) revert MockDreamDexInvalidOrderType(orderType);
    if (builder == address(0) && builderFeeBpsTimes1k != 0) {
      revert MockDreamDexBuilderMissing(builderFeeBpsTimes1k);
    }
    // Timestamp comparison is the behavior under test in this venue model.
    // forge-lint: disable-next-line(block-timestamp)
    if (expireTimestampNs <= block.timestamp * 1e9 || expireTimestampNs > marketExpiryNs) {
      revert MockDreamDexInvalidDeadline(expireTimestampNs);
    }

    OrderBookParameters memory parameters = _orderBookParameters;
    if (
      price == 0 || price >= _info.oneCollateral || price % parameters.tickSize != 0
        || quantity < parameters.minQuantity || quantity % parameters.lotSize != 0
    ) revert MockDreamDexInvalidGrid(price, quantity);

    lastKind = kind;
    lastPrice = price;
    lastQuantity = quantity;
    lastDeadlineNs = expireTimestampNs;
    lastSubmittedAt = block.timestamp;
    ++submissionCount;
    lastOrderType = orderType;
    lastSelfMatchingOption = selfMatchingOption;
    lastBuilder = builder;
    lastBuilderFeeBpsTimes1k = builderFeeBpsTimes1k;
    lastUserData = userData;

    uint256 filled = quantity * fillBps / _BPS;
    filled -= filled % parameters.lotSize;
    if (filled == 0 || (orderType == 1 && filled != quantity)) return (success, id);

    _execute(kind, price, filled);
    success = true;
    id = returnedOrderId;
  }

  /// @inheritdoc IDreamDexBinaryPool
  function mintSet(address yesTo, address noTo, uint256 amount) external override {
    bool transferred =
      IERC20Minimal(_info.collateralToken).transferFrom(msg.sender, address(this), amount);
    if (!transferred) revert MockDreamDexTransferFailed();
    MockERC6909(_info.outcomeToken).mint(yesTo, _info.yesId, amount);
    MockERC6909(_info.outcomeToken).mint(noTo, _info.noId, amount);
  }

  /// @inheritdoc IDreamDexBinaryPool
  function burnSet(uint256 amount) external override {
    IERC6909 outcome = IERC6909(_info.outcomeToken);
    bool yesTransferred = outcome.transferFrom(msg.sender, address(this), _info.yesId, amount);
    bool noTransferred = outcome.transferFrom(msg.sender, address(this), _info.noId, amount);
    if (!yesTransferred || !noTransferred) revert MockDreamDexTransferFailed();
    MockERC6909(_info.outcomeToken).burn(address(this), _info.yesId, amount);
    MockERC6909(_info.outcomeToken).burn(address(this), _info.noId, amount);
    bool transferred = IERC20Minimal(_info.collateralToken).transfer(msg.sender, amount);
    if (!transferred) revert MockDreamDexTransferFailed();
  }

  /// @notice Applies an immediate mock fill using actual token transfers.
  /// @param kind Binary order kind.
  /// @param yesPrice YES-side price in raw collateral units.
  /// @param quantity Filled outcome quantity.
  function _execute(uint8 kind, uint256 yesPrice, uint256 quantity) internal {
    bool isYes = kind < 2;
    bool isBuy = kind == 0 || kind == 2;
    uint256 outcomeId = isYes ? _info.yesId : _info.noId;
    uint256 sidePrice = isYes ? yesPrice : _info.oneCollateral - yesPrice;
    uint256 collateralAmount = quantity * sidePrice / _info.oneCollateral;
    if (isBuy && mulmod(quantity, sidePrice, _info.oneCollateral) != 0) ++collateralAmount;

    if (isBuy) {
      bool collateralTransferred = IERC20Minimal(_info.collateralToken)
        .transferFrom(msg.sender, address(this), collateralAmount);
      bool outcomeTransferred =
        IERC6909(_info.outcomeToken).transfer(msg.sender, outcomeId, quantity);
      if (!collateralTransferred || !outcomeTransferred) revert MockDreamDexTransferFailed();
    } else {
      bool outcomeTransferred =
        IERC6909(_info.outcomeToken).transferFrom(msg.sender, address(this), outcomeId, quantity);
      bool collateralTransferred =
        IERC20Minimal(_info.collateralToken).transfer(msg.sender, collateralAmount);
      if (!outcomeTransferred || !collateralTransferred) revert MockDreamDexTransferFailed();
    }
  }
}
