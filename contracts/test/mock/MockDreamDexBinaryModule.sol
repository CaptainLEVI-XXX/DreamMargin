// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary-module test model
/// @author DreamMargin contributors
/// @notice Stores exact market records used to test adapter generation validation.
/// @dev Complete-set and redemption calls record arguments but do not model settlement economics.

import {IDreamDexBinaryModule} from "src/interfaces/integrations/IDreamDexBinaryModule.sol";

/// @notice Raised when a test queries an unregistered market.
/// @param marketId Missing DreamDEX market identifier.
error MockDreamDexMarketMissing(bytes32 marketId);

/// @notice Raised when the mock settlement dependency is zero.
error MockDreamDexModuleZeroAddress();

/// @notice Mutable module record matching the deployed `markets` return tuple.
/// @param oracleQuestionId Oracle question bound to the market.
/// @param outcomeSlotCount Number of outcome slots.
/// @param voidPolicy Market void policy.
/// @param collateral Collateral token.
/// @param originOperatorId Originating operator identifier.
/// @param originVenueId Originating venue identifier.
/// @param oracleAdapter Oracle adapter.
/// @param creator Market creator.
/// @param market Binary market state contract.
/// @param pool Recyclable binary pool.
/// @param yesId YES outcome ID.
/// @param noId NO outcome ID.
/// @param tradingStart Trading-start timestamp in seconds.
/// @param expiry Trading-expiry timestamp in seconds.
struct MockModuleMarket {
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

/// @notice Local DreamDEX module-record model.
contract MockDreamDexBinaryModule is IDreamDexBinaryModule {
  /// @inheritdoc IDreamDexBinaryModule
  address public immutable override settlement;

  /// @inheritdoc IDreamDexBinaryModule
  mapping(bytes32 marketId => uint64 nonce) public override marketNonce;

  /// @notice Registered market tuples.
  mapping(bytes32 marketId => MockModuleMarket record) private _markets;

  /// @notice Whether a market identifier has a registered record.
  mapping(bytes32 marketId => bool registered) private _registered;

  /// @notice Last write action selector recorded by the mock.
  bytes4 public lastAction;

  /// @notice Last market identifier passed to a write action.
  bytes32 public lastMarketId;

  /// @notice Last outcome index passed to redemption.
  uint8 public lastOutcomeIndex;

  /// @notice Last amount passed to a write action.
  uint256 public lastAmount;

  /// @notice Creates a module model bound to one settlement singleton.
  /// @param settlement_ Settlement contract address.
  constructor(address settlement_) {
    if (settlement_ == address(0)) revert MockDreamDexModuleZeroAddress();
    settlement = settlement_;
  }

  /// @notice Registers or replaces one full market record and generation nonce.
  /// @param marketId DreamDEX market identifier.
  /// @param nonce Current generation nonce.
  /// @param record Full module market record.
  function setMarket(bytes32 marketId, uint64 nonce, MockModuleMarket calldata record) external {
    marketNonce[marketId] = nonce;
    _markets[marketId] = record;
    _registered[marketId] = true;
  }

  /// @inheritdoc IDreamDexBinaryModule
  function markets(bytes32 marketId)
    external
    view
    override
    returns (
      uint256 oracleQuestionId,
      uint8 outcomeSlotCount,
      uint8 voidPolicy,
      address collateral,
      uint32 originOperatorId,
      bytes32 originVenueId,
      address oracleAdapter,
      address creator,
      address market,
      address pool,
      uint256 yesId,
      uint256 noId,
      uint64 tradingStart,
      uint64 expiry
    )
  {
    if (!_registered[marketId]) revert MockDreamDexMarketMissing(marketId);
    MockModuleMarket storage record = _markets[marketId];
    oracleQuestionId = record.oracleQuestionId;
    outcomeSlotCount = record.outcomeSlotCount;
    voidPolicy = record.voidPolicy;
    collateral = record.collateral;
    originOperatorId = record.originOperatorId;
    originVenueId = record.originVenueId;
    oracleAdapter = record.oracleAdapter;
    creator = record.creator;
    market = record.market;
    pool = record.pool;
    yesId = record.yesId;
    noId = record.noId;
    tradingStart = record.tradingStart;
    expiry = record.expiry;
  }

  /// @inheritdoc IDreamDexBinaryModule
  function redeem(uint32, bytes32, bytes32 marketId, uint8 outcomeIdx, uint256 amount)
    external
    override
  {
    lastAction = this.redeem.selector;
    lastMarketId = marketId;
    lastOutcomeIndex = outcomeIdx;
    lastAmount = amount;
  }

  /// @inheritdoc IDreamDexBinaryModule
  function mintCompleteSet(uint32, bytes32, bytes32 marketId, uint256 amount) external override {
    lastAction = this.mintCompleteSet.selector;
    lastMarketId = marketId;
    lastAmount = amount;
  }

  /// @inheritdoc IDreamDexBinaryModule
  function mergeCompleteSet(uint32, bytes32, bytes32 marketId, uint256 amount) external override {
    lastAction = this.mergeCompleteSet.selector;
    lastMarketId = marketId;
    lastAmount = amount;
  }
}
