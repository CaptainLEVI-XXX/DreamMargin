// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title DreamDEX adapter test harness
/// @author DreamMargin contributors
/// @notice Exposes stateless internal generation and execution helpers to tests.
/// @dev The module binding is immutable test bytecode and introduces no storage slot.

import {DreamDexAdapter} from "src/adapters/DreamDexAdapter.sol";

import {LibDreamMarginErrors} from "src/libs/dreammargin/LibDreamMarginErrors.sol";
import {MarketKey} from "src/libs/dreammargin/LibDreamMarginStorage.sol";

/// @notice Concrete wrapper around the abstract stateless adapter.
contract DreamDexAdapterHarness is DreamDexAdapter {
  /// @notice Statically bound mock DreamDEX module.
  address public immutable MODULE;

  /// @notice Binds the harness to one module deployment.
  /// @param module_ Mock DreamDEX binary module.
  constructor(address module_) {
    if (module_ == address(0)) revert LibDreamMarginErrors.ZeroAddress("MODULE");
    MODULE = module_;
  }

  /// @notice Exposes full generation validation.
  /// @param key Exact market-generation tuple.
  /// @param outcomeIndex Zero for YES or one for NO.
  /// @param requireTrading Whether the market must currently be Trading.
  /// @return generation Normalized deployed generation state.
  function validateGeneration(MarketKey calldata key, uint8 outcomeIndex, bool requireTrading)
    external
    view
    returns (ValidatedGeneration memory generation)
  {
    generation = _validateGeneration(MODULE, key, outcomeIndex, requireTrading);
  }

  /// @notice Exposes an immediate buy from harness-owned collateral.
  /// @param order User-bounded order request.
  /// @return result Actual balance-derived fill.
  function buyOutcome(ImmediateOrder calldata order)
    external
    returns (ExecutionResult memory result)
  {
    result = _buyOutcome(MODULE, order);
  }

  /// @notice Exposes an immediate sell from harness-owned outcome collateral.
  /// @param order User-bounded order request.
  /// @return result Actual balance-derived fill.
  function sellOutcome(ImmediateOrder calldata order)
    external
    returns (ExecutionResult memory result)
  {
    result = _sellOutcome(MODULE, order);
  }
}
