#!/usr/bin/env bash
set -euo pipefail

# This is a future live-deployment verification template. The fork rehearsal never
# invokes it because local mirror addresses do not exist on the Shannon explorer.
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
: "${SOMNIA_VERIFIER_URL:?set SOMNIA_VERIFIER_URL}"
: "${VAULT_ADDRESS:?set VAULT_ADDRESS}"
: "${ORACLE_ADDRESS:?set ORACLE_ADDRESS}"
: "${CONTROLLER_ADDRESS:?set CONTROLLER_ADDRESS}"
: "${POSITION_OPEN_FACET:?set POSITION_OPEN_FACET}"
: "${POSITION_CLOSE_FACET:?set POSITION_CLOSE_FACET}"
: "${POSITION_LIQUIDATION_FACET:?set POSITION_LIQUIDATION_FACET}"
: "${POSITION_SETTLEMENT_FACET:?set POSITION_SETTLEMENT_FACET}"
: "${VAULT_CONSTRUCTOR_ARGS:?set ABI-encoded VAULT_CONSTRUCTOR_ARGS}"
: "${ORACLE_CONSTRUCTOR_ARGS:?set ABI-encoded ORACLE_CONSTRUCTOR_ARGS}"
: "${CONTROLLER_CONSTRUCTOR_ARGS:?set ABI-encoded CONTROLLER_CONSTRUCTOR_ARGS}"

verify() {
  forge verify-contract \
    --chain 50312 \
    --rpc-url "$SOMNIA_RPC_URL" \
    --verifier blockscout \
    --verifier-url "$SOMNIA_VERIFIER_URL" \
    --compiler-version 0.8.34 \
    --evm-version prague \
    --num-of-optimizations 200 \
    --via-ir \
    --watch \
    "$@"
}

verify "$POSITION_OPEN_FACET" src/dreammargin/base/PositionOpen.sol:PositionOpen
verify "$POSITION_CLOSE_FACET" src/dreammargin/base/PositionClose.sol:PositionClose
verify "$POSITION_LIQUIDATION_FACET" \
  src/dreammargin/base/PositionLiquidation.sol:PositionLiquidation
verify "$POSITION_SETTLEMENT_FACET" \
  src/dreammargin/base/PositionSettlement.sol:PositionSettlement
verify --constructor-args "$VAULT_CONSTRUCTOR_ARGS" \
  "$VAULT_ADDRESS" src/vault/DreamMarginVault.sol:DreamMarginVault
verify --constructor-args "$ORACLE_CONSTRUCTOR_ARGS" \
  "$ORACLE_ADDRESS" src/oracle/DreamDexMarkOracle.sol:DreamDexMarkOracle
verify --constructor-args "$CONTROLLER_CONSTRUCTOR_ARGS" \
  "$CONTROLLER_ADDRESS" src/dreammargin/DreamMarginController.sol:DreamMarginController
