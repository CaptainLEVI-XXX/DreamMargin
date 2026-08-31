// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary markets module interface
/// @author DreamMargin contributors
/// @notice Exposes market-generation records, complete sets, and redemption.
/// @dev The module is a pinned integration. Operator and venue fields are
///      attribution values and do not replace DreamMargin authorization.
interface IDreamDexBinaryModule {
  /// @notice Returns the permanent binary settlement contract.
  /// @return settlement_ Settlement contract address.
  function settlement() external view returns (address settlement_);

  /// @notice Returns the generation nonce registered for a market ID.
  /// @param marketId DreamDEX market identifier.
  /// @return nonce Current pool generation nonce.
  function marketNonce(bytes32 marketId) external view returns (uint64 nonce);

  /// @notice Returns the immutable and current addresses recorded for a market.
  /// @param marketId DreamDEX market identifier.
  /// @return oracleQuestionId Oracle question bound to the market.
  /// @return outcomeSlotCount Number of outcome slots.
  /// @return voidPolicy Market void policy enum.
  /// @return collateral Collateral token address.
  /// @return originOperatorId Originating operator identifier.
  /// @return originVenueId Originating venue identifier.
  /// @return oracleAdapter Oracle adapter address.
  /// @return creator Market creator address.
  /// @return market Binary market state contract.
  /// @return pool Recyclable binary pool address.
  /// @return yesId ERC-6909 YES token ID.
  /// @return noId ERC-6909 NO token ID.
  /// @return tradingStart Trading-start timestamp in seconds.
  /// @return expiry Trading-expiry timestamp in seconds.
  function markets(bytes32 marketId)
    external
    view
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
    );

  /// @notice Redeems one terminal outcome through the module.
  /// @param operatorId Attribution operator ID, zero when unused.
  /// @param venueId Attribution venue ID, zero when unused.
  /// @param marketId DreamDEX market identifier.
  /// @param outcomeIdx Outcome index, zero for YES or one for NO.
  /// @param amount Outcome amount redeemed.
  function redeem(
    uint32 operatorId,
    bytes32 venueId,
    bytes32 marketId,
    uint8 outcomeIdx,
    uint256 amount
  ) external;

  /// @notice Mints a complete set through the module.
  /// @param operatorId Attribution operator ID, zero when unused.
  /// @param venueId Attribution venue ID, zero when unused.
  /// @param marketId DreamDEX market identifier.
  /// @param amount Complete-set amount.
  function mintCompleteSet(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint256 amount)
    external;

  /// @notice Merges a complete set through the module.
  /// @param operatorId Attribution operator ID, zero when unused.
  /// @param venueId Attribution venue ID, zero when unused.
  /// @param marketId DreamDEX market identifier.
  /// @param amount Complete-set amount.
  function mergeCompleteSet(uint32 operatorId, bytes32 venueId, bytes32 marketId, uint256 amount)
    external;
}
