#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
MANIFEST="$CONTRACTS_DIR/deployments/shannon-deployment.json"

if [[ ! -f "$ENV_FILE" || ! -f "$MANIFEST" ]]; then
  echo "Missing .env or deployments/shannon-deployment.json." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
SOMNIA_VERIFIER_URL="${SOMNIA_VERIFIER_URL:-${SHANNON_EXPLORER_URL%/}/api}"

address() { jq -r ".$1" "$MANIFEST"; }
argument() { jq -r ".$1" "$MANIFEST"; }

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

cd "$CONTRACTS_DIR"
verify "$(address transientProbe)" script/DeployShannon.s.sol:ShannonTransientProbe
verify "$(address positionOpenFacet)" src/dreammargin/base/PositionOpen.sol:PositionOpen
verify "$(address positionCloseFacet)" src/dreammargin/base/PositionClose.sol:PositionClose
verify "$(address positionLiquidationFacet)" \
  src/dreammargin/base/PositionLiquidation.sol:PositionLiquidation
verify "$(address positionSettlementFacet)" \
  src/dreammargin/base/PositionSettlement.sol:PositionSettlement
verify --constructor-args "$(argument vaultConstructorArgs)" \
  "$(address vault)" src/vault/DreamMarginVault.sol:DreamMarginVault
verify --constructor-args "$(argument oracleConstructorArgs)" \
  "$(address oracle)" src/oracle/DreamDexMarkOracle.sol:DreamDexMarkOracle
verify --constructor-args "$(argument controllerConstructorArgs)" \
  "$(address controller)" src/dreammargin/DreamMarginController.sol:DreamMarginController
