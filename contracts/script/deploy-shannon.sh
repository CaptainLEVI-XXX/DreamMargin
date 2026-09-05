#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
PROGRESS="$CONTRACTS_DIR/deployments/shannon-deployment-progress.json"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"

MODULE="0x3ecC694Cef705358864a646142ac17A90E29e388"
COLLATERAL="0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E"
OUTCOME_TOKEN="0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9"
ANNUAL_RATE_WAD="50000000000000000"
MAX_DEBT_GLOBAL="40000000000"
MAX_DAILY_LOSS="5000000000"
MAX_UTILIZATION_BPS="8000"
LOSS_WINDOW="86400"
LOSS_COOLDOWN="3600"
GOVERNANCE_DELAY_SECONDS="${GOVERNANCE_DELAY_SECONDS:-60}"

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

code_hash() {
  cast code "$1" --rpc-url "$RPC_URL" | cast keccak
}

account="$(cast wallet address --private-key "$PRIVATE_KEY")"
current_nonce="$(cast nonce "$account" --rpc-url "$RPC_URL")"
transient_probe=""
transient_validated=false
position_open=""
position_close=""
position_liquidation=""
position_settlement=""
vault=""
oracle=""
controller=""

if [[ "${FORCE_REDEPLOY:-0}" == "1" ]]; then
  starting_nonce="$current_nonce"
  echo "Starting a fresh deployment at wallet nonce $starting_nonce; prior addresses will be superseded."
elif [[ -f "$PROGRESS" ]]; then
  starting_nonce="$(jq -r '.deployerStartingNonce' "$PROGRESS")"
  expected_nonce="$(jq -r '.nextNonce' "$PROGRESS")"
  if [[ "$(jq -r '.deployer | ascii_downcase' "$PROGRESS")" != "$(lower "$account")" ]]; then
    echo "Deployment progress belongs to a different wallet." >&2
    exit 1
  fi
  if [[ "$current_nonce" != "$expected_nonce" ]]; then
    echo "Wallet nonce changed outside this workflow; refusing an unsafe resume." >&2
    exit 1
  fi
  transient_probe="$(jq -r '.transientProbe // empty' "$PROGRESS")"
  transient_validated="$(jq -r '.transientValidated // false' "$PROGRESS")"
  position_open="$(jq -r '.positionOpenFacet // empty' "$PROGRESS")"
  position_close="$(jq -r '.positionCloseFacet // empty' "$PROGRESS")"
  position_liquidation="$(jq -r '.positionLiquidationFacet // empty' "$PROGRESS")"
  position_settlement="$(jq -r '.positionSettlementFacet // empty' "$PROGRESS")"
  vault="$(jq -r '.vault // empty' "$PROGRESS")"
  oracle="$(jq -r '.oracle // empty' "$PROGRESS")"
  controller="$(jq -r '.controller // empty' "$PROGRESS")"
else
  starting_nonce="$current_nonce"
fi
predicted_controller="$(cast compute-address "$account" --nonce "$((starting_nonce + 8))")"

save_progress() {
  local next_nonce="$1"
  jq -n \
    --arg deployer "$account" \
    --argjson deployerStartingNonce "$starting_nonce" \
    --argjson nextNonce "$next_nonce" \
    --arg transientProbe "$transient_probe" \
    --argjson transientValidated "$transient_validated" \
    --arg positionOpenFacet "$position_open" \
    --arg positionCloseFacet "$position_close" \
    --arg positionLiquidationFacet "$position_liquidation" \
    --arg positionSettlementFacet "$position_settlement" \
    --arg vault "$vault" \
    --arg oracle "$oracle" \
    --arg controller "$controller" \
    '{deployer:$deployer,deployerStartingNonce:$deployerStartingNonce,nextNonce:$nextNonce,transientProbe:$transientProbe,transientValidated:$transientValidated,positionOpenFacet:$positionOpenFacet,positionCloseFacet:$positionCloseFacet,positionLiquidationFacet:$positionLiquidationFacet,positionSettlementFacet:$positionSettlementFacet,vault:$vault,oracle:$oracle,controller:$controller}' \
    >"$PROGRESS"
}

deploy_contract() {
  local result_var="$1"
  local label="$2"
  local contract="$3"
  shift 3
  local result deployed tx_hash
  result="$(forge create "$contract" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --timeout 120 \
    --json \
    "$@")"
  deployed="$(jq -r '.deployedTo // empty' <<<"$result")"
  tx_hash="$(jq -r '.transactionHash // empty' <<<"$result")"
  if [[ ! "$deployed" =~ ^0x[0-9a-fA-F]{40}$ || ! "$tx_hash" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "Could not parse $label deployment result." >&2
    exit 1
  fi
  echo "$label deployed at $deployed ($tx_hash)"
  printf -v "$result_var" '%s' "$deployed"
}

cd "$CONTRACTS_DIR"
if [[ -z "$transient_probe" ]]; then
  deploy_contract transient_probe "Transient probe" \
    script/DeployShannon.s.sol:ShannonTransientProbe
  save_progress "$((starting_nonce + 1))"
fi
if [[ "$transient_validated" != "true" ]]; then
  probe_receipt="$(cast send "$transient_probe" "probe()(bytes4)" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$probe_receipt")" != "0x1" ]]; then
    echo "Shannon transient-storage probe reverted." >&2
    exit 1
  fi
  transient_validated=true
  save_progress "$((starting_nonce + 2))"
  echo "Transient-storage execution confirmed."
fi

if [[ -z "$position_open" ]]; then
  deploy_contract position_open "PositionOpen" src/dreammargin/base/PositionOpen.sol:PositionOpen
  save_progress "$((starting_nonce + 3))"
fi
if [[ -z "$position_close" ]]; then
  deploy_contract position_close "PositionClose" src/dreammargin/base/PositionClose.sol:PositionClose
  save_progress "$((starting_nonce + 4))"
fi
if [[ -z "$position_liquidation" ]]; then
  deploy_contract position_liquidation "PositionLiquidation" \
    src/dreammargin/base/PositionLiquidation.sol:PositionLiquidation
  save_progress "$((starting_nonce + 5))"
fi
if [[ -z "$position_settlement" ]]; then
  deploy_contract position_settlement "PositionSettlement" \
    src/dreammargin/base/PositionSettlement.sol:PositionSettlement
  save_progress "$((starting_nonce + 6))"
fi
if [[ -z "$vault" ]]; then
  deploy_contract vault "Vault" src/vault/DreamMarginVault.sol:DreamMarginVault \
    --constructor-args "$COLLATERAL" "$predicted_controller" "$ANNUAL_RATE_WAD"
  save_progress "$((starting_nonce + 7))"
fi
if [[ -z "$oracle" ]]; then
  deploy_contract oracle "Oracle" src/oracle/DreamDexMarkOracle.sol:DreamDexMarkOracle \
    --constructor-args "$MODULE" "$predicted_controller"
  save_progress "$((starting_nonce + 8))"
fi
if [[ -z "$controller" ]]; then
  deploy_contract controller "Controller" \
    src/dreammargin/DreamMarginController.sol:DreamMarginController \
    --constructor-args \
    "$MODULE" "$vault" "$oracle" "$account" \
    "$position_open" "$position_close" "$position_liquidation" "$position_settlement" \
    "($account,$account,$account,$account)" \
    "($MAX_DEBT_GLOBAL,$MAX_DAILY_LOSS,$MAX_UTILIZATION_BPS,$GOVERNANCE_DELAY_SECONDS,$LOSS_WINDOW,$LOSS_COOLDOWN)"
  save_progress "$((starting_nonce + 9))"
fi

if [[ "$(lower "$controller")" != "$(lower "$predicted_controller")" ]]; then
  echo "Controller address does not match the pre-bound vault/oracle address." >&2
  exit 1
fi

vault_args="$(cast abi-encode "constructor(address,address,uint256)" \
  "$COLLATERAL" "$controller" "$ANNUAL_RATE_WAD")"
oracle_args="$(cast abi-encode "constructor(address,address)" "$MODULE" "$controller")"
controller_args="$(cast abi-encode \
  "constructor(address,address,address,address,address,address,address,address,(address,address,address,address),(uint256,uint256,uint16,uint40,uint40,uint40))" \
  "$MODULE" "$vault" "$oracle" "$account" \
  "$position_open" "$position_close" "$position_liquidation" "$position_settlement" \
  "($account,$account,$account,$account)" \
  "($MAX_DEBT_GLOBAL,$MAX_DAILY_LOSS,$MAX_UTILIZATION_BPS,$GOVERNANCE_DELAY_SECONDS,$LOSS_WINDOW,$LOSS_COOLDOWN)")"

jq -n \
  --arg schema "dreammargin.shannon-deployment.v1" \
  --arg network "somnia-shannon" \
  --argjson chainId 50312 \
  --argjson deployedAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
  --argjson deployerStartingNonce "$starting_nonce" \
  --arg deployer "$account" \
  --arg dreamDexModule "$MODULE" \
  --arg collateral "$COLLATERAL" \
  --arg outcomeToken "$OUTCOME_TOKEN" \
  --arg transientProbe "$transient_probe" \
  --arg positionOpenFacet "$position_open" \
  --arg positionCloseFacet "$position_close" \
  --arg positionLiquidationFacet "$position_liquidation" \
  --arg positionSettlementFacet "$position_settlement" \
  --arg vault "$vault" \
  --arg oracle "$oracle" \
  --arg controller "$controller" \
  --arg transientProbeCodehash "$(code_hash "$transient_probe")" \
  --arg positionOpenCodehash "$(code_hash "$position_open")" \
  --arg positionCloseCodehash "$(code_hash "$position_close")" \
  --arg positionLiquidationCodehash "$(code_hash "$position_liquidation")" \
  --arg positionSettlementCodehash "$(code_hash "$position_settlement")" \
  --arg vaultCodehash "$(code_hash "$vault")" \
  --arg oracleCodehash "$(code_hash "$oracle")" \
  --arg controllerCodehash "$(code_hash "$controller")" \
  --arg vaultConstructorArgs "$vault_args" \
  --arg oracleConstructorArgs "$oracle_args" \
  --arg controllerConstructorArgs "$controller_args" \
  --argjson annualRateWad "$ANNUAL_RATE_WAD" \
  --argjson governanceDelaySeconds "$GOVERNANCE_DELAY_SECONDS" \
  --argjson maxDebtGlobal "$MAX_DEBT_GLOBAL" \
  --argjson maxDailyRealizedLoss "$MAX_DAILY_LOSS" \
  --argjson maxVaultUtilizationBps "$MAX_UTILIZATION_BPS" \
  '{schema:$schema,network:$network,chainId:$chainId,deployedAtBlock:$deployedAtBlock,deployerStartingNonce:$deployerStartingNonce,testnetOnly:true,productionReady:false,singleWalletRoles:true,secretExcluded:true,solcVersion:"0.8.34",evmVersion:"prague",optimizerRuns:200,viaIr:true,deployer:$deployer,governance:$deployer,riskSteward:$deployer,guardian:$deployer,feeCollector:$deployer,feeRecipient:$deployer,dreamDexModule:$dreamDexModule,collateral:$collateral,outcomeToken:$outcomeToken,transientProbe:$transientProbe,positionOpenFacet:$positionOpenFacet,positionCloseFacet:$positionCloseFacet,positionLiquidationFacet:$positionLiquidationFacet,positionSettlementFacet:$positionSettlementFacet,vault:$vault,oracle:$oracle,controller:$controller,transientProbeCodehash:$transientProbeCodehash,positionOpenCodehash:$positionOpenCodehash,positionCloseCodehash:$positionCloseCodehash,positionLiquidationCodehash:$positionLiquidationCodehash,positionSettlementCodehash:$positionSettlementCodehash,vaultCodehash:$vaultCodehash,oracleCodehash:$oracleCodehash,controllerCodehash:$controllerCodehash,annualRateWad:$annualRateWad,governanceDelaySeconds:$governanceDelaySeconds,maxDebtGlobal:$maxDebtGlobal,maxDailyRealizedLoss:$maxDailyRealizedLoss,maxVaultUtilizationBps:$maxVaultUtilizationBps,vaultConstructorArgs:$vaultConstructorArgs,oracleConstructorArgs:$oracleConstructorArgs,controllerConstructorArgs:$controllerConstructorArgs}' \
  >"$OUTPUT"

roles="$(cast call "$controller" "rolesOf(address)(uint256)" "$account" --rpc-url "$RPC_URL")"
if [[ "$roles" != "15" ]]; then
  echo "Controller role validation failed: expected 15, got $roles." >&2
  exit 1
fi
echo "Validated all bindings and wrote $OUTPUT"
