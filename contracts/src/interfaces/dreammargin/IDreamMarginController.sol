// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller interface
/// @author DreamMargin contributors
/// @notice Exposes isolated-position lifecycle actions and transparent state views.
/// @dev Risk-increasing calls bind the exact DreamDEX generation, deadline, and execution limits.

import {
  GenerationConfig,
  MarketKey,
  Position,
  ProtocolMode
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

interface IDreamMarginController {
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

  /// @notice Emitted when exact outcome collateral is added without increasing debt.
  /// @param positionId Position receiving collateral.
  /// @param owner Account supplying the exact recorded outcome ID.
  /// @param shares Outcome shares added.
  event CollateralAdded(uint256 indexed positionId, address indexed owner, uint256 shares);

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

  /// @notice Opens one isolated leveraged position atomically.
  /// @param params Exact generation, collateral, leverage, price, fill, and deadline bounds.
  /// @return positionId Newly allocated position identifier.
  /// @return sharesBought Additional outcome shares received from actual execution deltas.
  /// @return debtAssets Collateral debt created in native units.
  function openPosition(OpenParams calldata params)
    external
    returns (uint256 positionId, uint256 sharesBought, uint256 debtAssets);

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

  /// @notice Returns one stored position.
  /// @param positionId Position identifier.
  /// @return position Stored position state.
  function getPosition(uint256 positionId) external view returns (Position memory position);

  /// @notice Returns one registered generation configuration.
  /// @param generationKey Full market-generation key.
  /// @return config Registered generation state and risk bounds.
  function getGeneration(bytes32 generationKey)
    external
    view
    returns (GenerationConfig memory config);

  /// @notice Returns the current protocol-wide operating mode.
  /// @return mode Current active, reduce-only, or paused mode.
  function protocolMode() external view returns (ProtocolMode mode);
}
