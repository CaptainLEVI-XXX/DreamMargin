// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX binary settlement integration interface
/// @author DreamMargin contributors
/// @notice Exposes frozen settlement records and direct outcome redemption.
/// @dev The payout vector is authoritative after finalization and can represent
///      an ordinary winner or a proportional void payout.
interface IDreamDexBinarySettlement {
  /// @notice Frozen settlement data for one pool generation.
  /// @param collateralToken Collateral paid on redemption.
  /// @param backing Collateral backing per complete set.
  /// @param finalized Whether the settlement record is terminal.
  /// @param voided Whether the market resolved through its void policy.
  /// @param settlementFeeBpsTimes1k Settlement fee in basis points times one thousand.
  /// @param feeRecipient Account receiving settlement fees.
  /// @param pool Pool bound to the frozen record.
  /// @param nonce Frozen pool generation nonce.
  /// @param payoutNumerators Per-outcome payout vector.
  struct SettlementRecord {
    address collateralToken;
    uint128 backing;
    bool finalized;
    bool voided;
    uint256 settlementFeeBpsTimes1k;
    address feeRecipient;
    address pool;
    uint64 nonce;
    uint256[] payoutNumerators;
  }

  /// @notice Redeems caller-owned outcome tokens to a receiver.
  /// @param outcomeId ERC-6909 outcome-token ID.
  /// @param amount Outcome amount redeemed.
  /// @param to Account receiving collateral.
  /// @return collateralOut Collateral paid after settlement fees.
  function redeem(uint256 outcomeId, uint256 amount, address to)
    external
    returns (uint256 collateralOut);

  /// @notice Returns the frozen record for a settlement key.
  /// @param marketKey Settlement key derived by DreamDEX.
  /// @return record Frozen settlement record.
  function getSettlement(uint256 marketKey) external view returns (SettlementRecord memory record);

  /// @notice Returns whether an outcome's generation is finalized.
  /// @param outcomeId ERC-6909 outcome-token ID.
  /// @return finalized True when redemption data is frozen.
  function isFinalized(uint256 outcomeId) external view returns (bool finalized);

  /// @notice Returns the shared ERC-6909 outcome-token contract.
  /// @return token Outcome-token contract address.
  function outcomeToken() external view returns (address token);
}
