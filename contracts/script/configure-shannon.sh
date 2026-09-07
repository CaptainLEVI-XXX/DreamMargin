#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
SELECTION="$CONTRACTS_DIR/deployments/shannon-selected-markets.json"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-market-configuration.json"
MODE="${1:?use schedule or execute}"

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
CONTROLLER="$(jq -r '.controller' "$DEPLOYMENT")"
ACCOUNT="$(cast wallet address --private-key "$PRIVATE_KEY")"
MIN_AGE="${ORACLE_MIN_AGE_SECONDS:-60}"
UPDATE_INTERVAL="${ORACLE_UPDATE_INTERVAL_SECONDS:-30}"
STALE_AFTER="${ORACLE_STALE_AFTER_SECONDS:-600}"
MIN_INTERVAL="${SERIES_MIN_INTERVAL_SECONDS:-3600}"

MARKETS_SIGNATURE='markets(bytes32)(uint256,uint8,uint8,address,uint32,bytes32,address,address,address,address,uint256,uint256,uint64,uint64)'
SCHEDULE_SIGNATURE='scheduleSeriesPolicyChange(bytes32,bytes32,(address,bytes32,uint32,address,uint64,(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),(uint40,uint40,uint40,uint128,uint16,uint16),bool,bool))'
EXECUTE_SIGNATURE='executeSeriesPolicyChange(bytes32,bytes32,(address,bytes32,uint32,address,uint64,(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),(uint40,uint40,uint40,uint128,uint16,uint16),bool,bool))'
ACTIVATE_SIGNATURE='activateSeriesGeneration((bytes32,address,uint64,address,uint256,address),uint8)'

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

if [[ "$MODE" != "schedule" && "$MODE" != "execute" ]]; then
  echo "Usage: $0 {schedule|execute}" >&2
  exit 1
fi

if [[ "$(lower "$ACCOUNT")" != "$(jq -r '.deployer | ascii_downcase' "$DEPLOYMENT")" ]]; then
  echo "PRIVATE_KEY does not match the deployment manifest." >&2
  exit 1
fi

if (( UPDATE_INTERVAL == 0 || MIN_AGE < UPDATE_INTERVAL || STALE_AFTER < MIN_AGE )); then
  echo "Invalid oracle timing relationship." >&2
  exit 1
fi
if (( MIN_INTERVAL <= 1200 + MIN_AGE )); then
  echo "SERIES_MIN_INTERVAL_SECONDS must exceed opening cutoff plus oracle age." >&2
  exit 1
fi

generation_key() {
  local encoded
  encoded="$(cast abi-encode 'f(bytes32,address,uint64,address,uint256,address)' \
    "$1" "$2" "$3" "$OUTCOME_TOKEN" "$4" "$COLLATERAL")"
  cast keccak "$encoded"
}

load_identity() {
  local prefix="$1"
  local market_id record record_collateral operator venue creator
  market_id="$(jq -r ".$prefix.marketId" "$SELECTION")"
  record="$(cast call "$MODULE" "$MARKETS_SIGNATURE" "$market_id" \
    --rpc-url "$RPC_URL" --json)"
  record_collateral="$(jq -r '.[3] | ascii_downcase' <<<"$record")"
  operator="$(jq -r '.[4]' <<<"$record")"
  venue="$(jq -r '.[5] | ascii_downcase' <<<"$record")"
  creator="$(jq -r '.[7]' <<<"$record")"

  if [[ "$record_collateral" != "$(lower "$COLLATERAL")" || \
    "$venue" != "$(lower "$DREAMDEX_VENUE_ID")" ]]; then
    echo "The $prefix series identity does not match the required collateral and venue." >&2
    exit 1
  fi

  printf -v "${prefix}_market_id" '%s' "$market_id"
  printf -v "${prefix}_creator" '%s' "$creator"
  printf -v "${prefix}_operator" '%s' "$operator"
  printf -v "${prefix}_venue" '%s' "$venue"
}

load_market() {
  local prefix="$1"
  local market_id selected_pool selected_nonce selected_expiry record
  local record_collateral operator venue creator pool yes_id no_id trading_start expiry interval
  market_id="$(jq -r ".$prefix.marketId" "$SELECTION")"
  selected_pool="$(jq -r ".$prefix.poolAddress | ascii_downcase" "$SELECTION")"
  selected_nonce="$(jq -r ".$prefix.nonce" "$SELECTION")"
  selected_expiry="$(jq -r ".$prefix.expiry" "$SELECTION")"
  record="$(cast call "$MODULE" "$MARKETS_SIGNATURE" "$market_id" \
    --rpc-url "$RPC_URL" --json)"
  record_collateral="$(jq -r '.[3] | ascii_downcase' <<<"$record")"
  operator="$(jq -r '.[4]' <<<"$record")"
  venue="$(jq -r '.[5] | ascii_downcase' <<<"$record")"
  creator="$(jq -r '.[7]' <<<"$record")"
  pool="$(jq -r '.[9]' <<<"$record")"
  yes_id="$(jq -r '.[10]' <<<"$record")"
  no_id="$(jq -r '.[11]' <<<"$record")"
  trading_start="$(jq -r '.[12]' <<<"$record")"
  expiry="$(jq -r '.[13]' <<<"$record")"
  interval="$((expiry - trading_start))"

  if [[ "$record_collateral" != "$(lower "$COLLATERAL")" || \
    "$venue" != "$(lower "$DREAMDEX_VENUE_ID")" ]]; then
    echo "The $prefix market does not match the required collateral and venue." >&2
    exit 1
  fi
  if [[ "$(lower "$pool")" != "$selected_pool" || "$expiry" != "$selected_expiry" ]]; then
    echo "The selected $prefix module record changed after discovery." >&2
    exit 1
  fi
  local module_nonce
  module_nonce="$(cast call "$MODULE" 'marketNonce(bytes32)(uint64)' "$market_id" \
    --rpc-url "$RPC_URL")"
  if [[ "$module_nonce" != "$selected_nonce" ]]; then
    echo "The selected $prefix pool has been recycled." >&2
    exit 1
  fi
  if (( interval < MIN_INTERVAL || expiry <= $(date +%s) + 1200 )); then
    echo "The selected $prefix market is too short or too close to expiry." >&2
    exit 1
  fi

  printf -v "${prefix}_market_id" '%s' "$market_id"
  printf -v "${prefix}_pool" '%s' "$pool"
  printf -v "${prefix}_nonce" '%s' "$module_nonce"
  printf -v "${prefix}_yes_id" '%s' "$yes_id"
  printf -v "${prefix}_no_id" '%s' "$no_id"
  printf -v "${prefix}_expiry" '%s' "$expiry"
  printf -v "${prefix}_creator" '%s' "$creator"
  printf -v "${prefix}_operator" '%s' "$operator"
  printf -v "${prefix}_venue" '%s' "$venue"
  printf -v "${prefix}_yes_key" '%s' "$(generation_key "$market_id" "$pool" "$module_nonce" "$yes_id")"
  printf -v "${prefix}_no_key" '%s' "$(generation_key "$market_id" "$pool" "$module_nonce" "$no_id")"
}

load_identity btc
load_identity eth
if [[ "$(lower "$btc_creator")" != "$(lower "$eth_creator")" || \
  "$btc_operator" != "$eth_operator" || "$btc_venue" != "$eth_venue" ]]; then
  echo "BTC and ETH do not share one reusable DreamDEX origin identity." >&2
  exit 1
fi

POLICY_ID="$(cast keccak 'SHANNON_DREAMDEX_ORIGIN_V1')"
POLICY_CHANGE_ID="$(cast keccak "$(cast abi-encode 'f(string,bytes32)' \
  'REGISTER_SHANNON_SERIES_POLICY_V1' "$POLICY_ID")")"
risk_tuple='(10000000000,20000000000,30000000000,1000000,6000,7500,8000,500,1000,1000,8000,20000,1200,600,3600,4,6,0)'
oracle_tuple="($MIN_AGE,$UPDATE_INTERVAL,$STALE_AFTER,25000000000,16,4)"
policy_tuple="($btc_creator,$btc_venue,$btc_operator,$COLLATERAL,$MIN_INTERVAL,$risk_tuple,$oracle_tuple,true,false)"

send_checked() {
  local label="$1"
  shift
  local receipt
  receipt="$(cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "$label failed." >&2
    exit 1
  fi
  echo "$label completed ($(jq -r '.transactionHash' <<<"$receipt"))."
}

if [[ "$MODE" == "schedule" ]]; then
  send_checked "Series policy schedule" "$CONTROLLER" "$SCHEDULE_SIGNATURE" \
    "$POLICY_CHANGE_ID" "$POLICY_ID" "$policy_tuple"
  exit 0
fi

current_policy="$(cast call "$CONTROLLER" 'policyFor(bytes32)(bytes32,bool)' "$btc_market_id" \
  --rpc-url "$RPC_URL" --json)"
if [[ "$(lower "$(jq -r '.[0]' <<<"$current_policy")")" == "$(lower "$POLICY_ID")" ]]; then
  echo "Reusing the executed series policy ($POLICY_ID)."
else
  send_checked "Series policy execution" "$CONTROLLER" "$EXECUTE_SIGNATURE" \
    "$POLICY_CHANGE_ID" "$POLICY_ID" "$policy_tuple"
fi

now="$(date +%s)"
btc_selected_expiry="$(jq -r '.btc.expiry' "$SELECTION")"
eth_selected_expiry="$(jq -r '.eth.expiry' "$SELECTION")"
if (( btc_selected_expiry <= now + 1200 || eth_selected_expiry <= now + 1200 )); then
  jq -n \
    --arg schema "dreammargin.shannon-markets.v2" \
    --argjson chainId 50312 \
    --argjson configuredAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
    --arg controller "$CONTROLLER" \
    --arg oracle "$(jq -r '.oracle' "$DEPLOYMENT")" \
    --arg policyId "$POLICY_ID" --arg policyChangeId "$POLICY_CHANGE_ID" \
    --arg creator "$btc_creator" --arg venueId "$btc_venue" \
    --argjson operatorId "$btc_operator" --argjson minimumIntervalSeconds "$MIN_INTERVAL" \
    '{schema:$schema,chainId:$chainId,configuredAtBlock:$configuredAtBlock,controller:$controller,oracle:$oracle,policyId:$policyId,policyChangeId:$policyChangeId,creator:$creator,venueId:$venueId,operatorId:$operatorId,minimumIntervalSeconds:$minimumIntervalSeconds,generationActivationPending:true}' \
    >"$OUTPUT"
  echo "Series policy is active; no fresh BTC/ETH selection is available for generation activation."
  echo "Wrote $OUTPUT"
  exit 0
fi

load_market btc
load_market eth

activate() {
  local prefix="$1"
  local outcome="$2"
  local index="$3"
  local market_id pool nonce outcome_id generation_key key_tuple admitted_by
  market_id="$(eval "printf '%s' \"\$${prefix}_market_id\"")"
  pool="$(eval "printf '%s' \"\$${prefix}_pool\"")"
  nonce="$(eval "printf '%s' \"\$${prefix}_nonce\"")"
  outcome_id="$(eval "printf '%s' \"\$${prefix}_${outcome}_id\"")"
  generation_key="$(eval "printf '%s' \"\$${prefix}_${outcome}_key\"")"
  admitted_by="$(cast call "$CONTROLLER" 'policyForGeneration(bytes32)(bytes32)' \
    "$generation_key" --rpc-url "$RPC_URL")"
  if [[ "$(lower "$admitted_by")" == "$(lower "$POLICY_ID")" ]]; then
    echo "Reusing activated $prefix $outcome ($generation_key)."
    return
  fi
  if [[ "$admitted_by" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]]; then
    echo "$prefix $outcome is linked to an unexpected policy $admitted_by." >&2
    exit 1
  fi
  key_tuple="($market_id,$pool,$nonce,$OUTCOME_TOKEN,$outcome_id,$COLLATERAL)"
  send_checked "Activated $prefix $outcome" "$CONTROLLER" "$ACTIVATE_SIGNATURE" \
    "$key_tuple" "$index"
}

activate btc yes 0
activate btc no 1
activate eth yes 0
activate eth no 1

for market_id in "$btc_market_id" "$eth_market_id"; do
  policy_result="$(cast call "$CONTROLLER" 'policyFor(bytes32)(bytes32,bool)' "$market_id" \
    --rpc-url "$RPC_URL" --json)"
  if [[ "$(lower "$(jq -r '.[0]' <<<"$policy_result")")" != "$(lower "$POLICY_ID")" || \
    "$(jq -r '.[1]' <<<"$policy_result")" != "true" ]]; then
    echo "Executed series policy is not eligible for $market_id." >&2
    exit 1
  fi
done

jq -n \
  --arg schema "dreammargin.shannon-markets.v2" \
  --argjson chainId 50312 \
  --argjson configuredAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
  --arg controller "$CONTROLLER" \
  --arg oracle "$(jq -r '.oracle' "$DEPLOYMENT")" \
  --arg policyId "$POLICY_ID" --arg policyChangeId "$POLICY_CHANGE_ID" \
  --arg creator "$btc_creator" --arg venueId "$btc_venue" \
  --argjson operatorId "$btc_operator" --argjson minimumIntervalSeconds "$MIN_INTERVAL" \
  --arg btcMarketId "$btc_market_id" --arg btcMarket "$(jq -r '.btc.marketAddress' "$SELECTION")" \
  --arg btcPool "$btc_pool" --argjson btcNonce "$btc_nonce" --argjson btcExpiry "$btc_expiry" \
  --arg ethMarketId "$eth_market_id" --arg ethMarket "$(jq -r '.eth.marketAddress' "$SELECTION")" \
  --arg ethPool "$eth_pool" --argjson ethNonce "$eth_nonce" --argjson ethExpiry "$eth_expiry" \
  --arg btcYesGenerationKey "$btc_yes_key" --arg btcNoGenerationKey "$btc_no_key" \
  --arg ethYesGenerationKey "$eth_yes_key" --arg ethNoGenerationKey "$eth_no_key" \
  --argjson oracleMinAgeSeconds "$MIN_AGE" \
  --argjson oracleUpdateIntervalSeconds "$UPDATE_INTERVAL" \
  --argjson oracleStaleAfterSeconds "$STALE_AFTER" \
  '{schema:$schema,chainId:$chainId,configuredAtBlock:$configuredAtBlock,controller:$controller,oracle:$oracle,policyId:$policyId,policyChangeId:$policyChangeId,creator:$creator,venueId:$venueId,operatorId:$operatorId,minimumIntervalSeconds:$minimumIntervalSeconds,btcMarketId:$btcMarketId,btcMarket:$btcMarket,btcPool:$btcPool,btcNonce:$btcNonce,btcExpiry:$btcExpiry,ethMarketId:$ethMarketId,ethMarket:$ethMarket,ethPool:$ethPool,ethNonce:$ethNonce,ethExpiry:$ethExpiry,btcYesGenerationKey:$btcYesGenerationKey,btcNoGenerationKey:$btcNoGenerationKey,ethYesGenerationKey:$ethYesGenerationKey,ethNoGenerationKey:$ethNoGenerationKey,oracleMinAgeSeconds:$oracleMinAgeSeconds,oracleUpdateIntervalSeconds:$oracleUpdateIntervalSeconds,oracleStaleAfterSeconds:$oracleStaleAfterSeconds}' \
  >"$OUTPUT"

echo "Wrote $OUTPUT"
