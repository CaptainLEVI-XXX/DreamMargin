// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamMargin controller-shell harness
/// @author DreamMargin contributors
/// @notice Makes the administrative shell deployable before lifecycle modules are composed.
/// @dev Lifecycle selectors deliberately revert and are replaced by production modules later.

import {DreamMarginController} from "src/dreammargin/DreamMarginController.sol";
import {IDreamMarginController} from "src/interfaces/dreammargin/IDreamMarginController.sol";
import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {
  GlobalRiskConfig,
  LibDreamMarginStorage
} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

/// @notice Test-only concrete controller with disabled lifecycle entrypoints.
contract DreamMarginControllerHarness is DreamMarginController {
  /// @notice Forwards every immutable binding and initial policy to the controller shell.
  constructor(
    address module_,
    address vault_,
    address oracle_,
    address feeRecipient_,
    address positionOpenFacet_,
    InitialRoles memory initialRoles,
    GlobalRiskConfig memory globalRisk
  )
    DreamMarginController(
      module_, vault_, oracle_, feeRecipient_, positionOpenFacet_, initialRoles, globalRisk
    )
  {}

  /// @notice Returns aggregate custody and debt attribution for lifecycle assertions.
  /// @param generationKey Exact generation identifier.
  /// @param marketGroup Shared market debt bucket.
  /// @param token Outcome-token contract.
  /// @param outcomeId Exact outcome ID.
  /// @return attributedShares Shares attributed to live positions for the exact ID.
  /// @return outcomeDebtShares Debt shares attributed to the exact generation.
  /// @return marketDebtShares Debt shares attributed to the shared market.
  /// @return totalDebtShares Debt shares attributed across the controller.
  function aggregateState(
    bytes32 generationKey,
    bytes32 marketGroup,
    address token,
    uint256 outcomeId
  )
    external
    view
    returns (
      uint256 attributedShares,
      uint256 outcomeDebtShares,
      uint256 marketDebtShares,
      uint256 totalDebtShares
    )
  {
    LibDreamMarginStorage.State storage self = LibDreamMarginStorage.get();
    attributedShares = self.attributedShares[token][outcomeId];
    outcomeDebtShares = self.outcomeDebtShares[generationKey];
    marketDebtShares = self.marketDebtShares[marketGroup];
    totalDebtShares = self.totalDebtShares;
  }

  /// @inheritdoc IDreamMarginController
  function repay(uint256, uint256) external pure override returns (uint256) {
    revert LibDreamMarginErrors.ActionBlocked(0, this.repay.selector);
  }

  /// @inheritdoc IDreamMarginController
  function withdrawCollateral(uint256, uint256) external pure override {
    revert LibDreamMarginErrors.ActionBlocked(0, this.withdrawCollateral.selector);
  }

  /// @inheritdoc IDreamMarginController
  function deleverage(DeleverageParams calldata) external pure override returns (uint256, uint256) {
    revert LibDreamMarginErrors.ActionBlocked(0, this.deleverage.selector);
  }

  /// @inheritdoc IDreamMarginController
  function close(CloseParams calldata) external pure override returns (uint256, uint256) {
    revert LibDreamMarginErrors.ActionBlocked(0, this.close.selector);
  }

  /// @inheritdoc IDreamMarginController
  function liquidate(LiquidationParams calldata)
    external
    pure
    override
    returns (uint256, uint256, uint256)
  {
    revert LibDreamMarginErrors.ActionBlocked(0, this.liquidate.selector);
  }

  /// @inheritdoc IDreamMarginController
  function settle(uint256) external pure override returns (uint256, uint256, uint256) {
    revert LibDreamMarginErrors.ActionBlocked(0, this.settle.selector);
  }
}
