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

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

if [[ "$(lower "$ACCOUNT")" != "$(jq -r '.deployer | ascii_downcase' "$DEPLOYMENT")" ]]; then
  echo "PRIVATE_KEY does not match the deployment manifest." >&2
  exit 1
fi

if (( UPDATE_INTERVAL == 0 || MIN_AGE < UPDATE_INTERVAL || STALE_AFTER < MIN_AGE )); then
  echo "Invalid oracle timing relationship." >&2
  exit 1
fi

SCHEDULE_SIGNATURE='scheduleGenerationChange(bytes32,bytes32,((bytes32,address,uint64,address,uint256,address),(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),bytes32,bool,bool),((bytes32,address,uint64,address,uint256,address),uint40,uint40,uint40,uint128,uint16,uint16,bool))'
EXECUTE_SIGNATURE='executeGenerationChange(bytes32,bytes32,((bytes32,address,uint64,address,uint256,address),(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),bytes32,bool,bool),((bytes32,address,uint64,address,uint256,address),uint40,uint40,uint40,uint128,uint16,uint16,bool))'

generation_key() {
  local encoded
  encoded="$(cast abi-encode 'f(bytes32,address,uint64,address,uint256,address)' \
    "$1" "$2" "$3" "$OUTCOME_TOKEN" "$4" "$COLLATERAL")"
  cast keccak "$encoded"
}

change_id() {
  local encoded
  encoded="$(cast abi-encode 'f(string,bytes32)' 'REGISTER_SHANNON_DAILY_V1' "$1")"
  cast keccak "$encoded"
}

load_registration() {
  local prefix="$1"
  local outcome="$2"
  local outcome_index="$3"
  local group="$4"
  local market_id pool nonce outcome_id market_address expiry interval venue status module_nonce key change
  market_id="$(jq -r ".$prefix.marketId" "$SELECTION")"
  pool="$(jq -r ".$prefix.poolAddress" "$SELECTION")"
  nonce="$(jq -r ".$prefix.nonce" "$SELECTION")"
  outcome_id="$(jq -r ".$prefix.${outcome}TokenId" "$SELECTION")"
  market_address="$(jq -r ".$prefix.marketAddress" "$SELECTION")"
  expiry="$(jq -r ".$prefix.expiry" "$SELECTION")"
  interval="$(jq -r ".$prefix.intervalSec" "$SELECTION")"
  venue="$(jq -r ".$prefix.venueId | ascii_downcase" "$SELECTION")"
  status="$(jq -r ".$prefix.clobStatus" "$SELECTION")"

  if [[ "$interval" != "86400" || "$status" != "Trading" || \
    "$venue" != "$(lower "$DREAMDEX_VENUE_ID")" ]]; then
    echo "Selected $prefix market no longer satisfies the discovery policy." >&2
    exit 1
  fi
  if (( expiry <= $(date +%s) + 1200 )); then
    echo "Selected $prefix market is too close to DreamMargin's opening cutoff." >&2
    exit 1
  fi
  module_nonce="$(cast call "$MODULE" 'marketNonce(bytes32)(uint64)' "$market_id" --rpc-url "$RPC_URL")"
  if [[ "$module_nonce" != "$nonce" ]]; then
    echo "Selected $prefix pool has been recycled." >&2
    exit 1
  fi
  if [[ "$(cast call "$market_address" 'status()(uint8)' --rpc-url "$RPC_URL")" != "1" ]]; then
    echo "Selected $prefix market is not trading on-chain." >&2
    exit 1
  fi

  key="$(generation_key "$market_id" "$pool" "$nonce" "$outcome_id")"
  change="$(change_id "$key")"
  local key_tuple risk_tuple generation_tuple oracle_tuple
  key_tuple="($market_id,$pool,$nonce,$OUTCOME_TOKEN,$outcome_id,$COLLATERAL)"
  risk_tuple="(100000000,300000000,500000000,1000000,6000,7500,8000,500,1000,1000,10000,20000,1200,600,3600,4,6,$outcome_index)"
  generation_tuple="($key_tuple,$risk_tuple,$group,true,false)"
  oracle_tuple="($key_tuple,$MIN_AGE,$UPDATE_INTERVAL,$STALE_AFTER,20000000,16,4,true)"

  REGISTRATION_KEY="$key"
  REGISTRATION_CHANGE="$change"
  REGISTRATION_GENERATION="$generation_tuple"
  REGISTRATION_ORACLE="$oracle_tuple"
}

send_registration() {
  local prefix="$1"
  local outcome="$2"
  local index="$3"
  local group="$4"
  load_registration "$prefix" "$outcome" "$index" "$group"
  local signature receipt
  signature="$SCHEDULE_SIGNATURE"
  [[ "$MODE" == "execute" ]] && signature="$EXECUTE_SIGNATURE"
  receipt="$(cast send "$CONTROLLER" "$signature" \
    "$REGISTRATION_CHANGE" "$REGISTRATION_KEY" \
    "$REGISTRATION_GENERATION" "$REGISTRATION_ORACLE" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "$MODE failed for $prefix $outcome." >&2
    exit 1
  fi
  echo "$MODE completed for $prefix $outcome ($REGISTRATION_KEY)."
  printf -v "${prefix}_${outcome}_key" '%s' "$REGISTRATION_KEY"
  printf -v "${prefix}_${outcome}_change" '%s' "$REGISTRATION_CHANGE"
}

if [[ "$MODE" != "schedule" && "$MODE" != "execute" ]]; then
  echo "Usage: $0 {schedule|execute}" >&2
  exit 1
fi

btc_group="$(cast keccak 'SHANNON_BTC_DAILY')"
eth_group="$(cast keccak 'SHANNON_ETH_DAILY')"
send_registration btc yes 0 "$btc_group"
send_registration btc no 1 "$btc_group"
send_registration eth yes 0 "$eth_group"
send_registration eth no 1 "$eth_group"

if [[ "$MODE" == "execute" ]]; then
  validate_generation() {
    local key="$1"
    local expected_pool="$2"
    local configured
    configured="$(cast call "$CONTROLLER" \
      'getGeneration(bytes32)(((bytes32,address,uint64,address,uint256,address),(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),bytes32,bool,bool))' \
      "$key" --rpc-url "$RPC_URL")"
    if [[ "$(lower "$configured")" != *"$(lower "$expected_pool")"* || "$configured" != *"true, false)" ]]; then
      echo "Could not validate executed generation $key." >&2
      exit 1
    fi
  }
  validate_generation "$btc_yes_key" "$(jq -r '.btc.poolAddress' "$SELECTION")"
  validate_generation "$btc_no_key" "$(jq -r '.btc.poolAddress' "$SELECTION")"
  validate_generation "$eth_yes_key" "$(jq -r '.eth.poolAddress' "$SELECTION")"
  validate_generation "$eth_no_key" "$(jq -r '.eth.poolAddress' "$SELECTION")"

  jq -n \
    --arg schema "dreammargin.shannon-markets.v1" \
    --argjson chainId 50312 \
    --argjson configuredAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
    --arg controller "$CONTROLLER" \
    --arg oracle "$(jq -r '.oracle' "$DEPLOYMENT")" \
    --arg btcMarketId "$(jq -r '.btc.marketId' "$SELECTION")" \
    --arg btcMarket "$(jq -r '.btc.marketAddress' "$SELECTION")" \
    --arg btcPool "$(jq -r '.btc.poolAddress' "$SELECTION")" \
    --argjson btcNonce "$(jq -r '.btc.nonce' "$SELECTION")" \
    --argjson btcExpiry "$(jq -r '.btc.expiry' "$SELECTION")" \
    --arg ethMarketId "$(jq -r '.eth.marketId' "$SELECTION")" \
    --arg ethMarket "$(jq -r '.eth.marketAddress' "$SELECTION")" \
    --arg ethPool "$(jq -r '.eth.poolAddress' "$SELECTION")" \
    --argjson ethNonce "$(jq -r '.eth.nonce' "$SELECTION")" \
    --argjson ethExpiry "$(jq -r '.eth.expiry' "$SELECTION")" \
    --arg btcYesGenerationKey "$btc_yes_key" \
    --arg btcNoGenerationKey "$btc_no_key" \
    --arg ethYesGenerationKey "$eth_yes_key" \
    --arg ethNoGenerationKey "$eth_no_key" \
    --arg btcYesChangeId "$btc_yes_change" \
    --arg btcNoChangeId "$btc_no_change" \
    --arg ethYesChangeId "$eth_yes_change" \
    --arg ethNoChangeId "$eth_no_change" \
    --argjson oracleMinAgeSeconds "$MIN_AGE" \
    --argjson oracleUpdateIntervalSeconds "$UPDATE_INTERVAL" \
    --argjson oracleStaleAfterSeconds "$STALE_AFTER" \
    '{schema:$schema,chainId:$chainId,configuredAtBlock:$configuredAtBlock,controller:$controller,oracle:$oracle,btcMarketId:$btcMarketId,btcMarket:$btcMarket,btcPool:$btcPool,btcNonce:$btcNonce,btcExpiry:$btcExpiry,ethMarketId:$ethMarketId,ethMarket:$ethMarket,ethPool:$ethPool,ethNonce:$ethNonce,ethExpiry:$ethExpiry,btcYesGenerationKey:$btcYesGenerationKey,btcNoGenerationKey:$btcNoGenerationKey,ethYesGenerationKey:$ethYesGenerationKey,ethNoGenerationKey:$ethNoGenerationKey,btcYesChangeId:$btcYesChangeId,btcNoChangeId:$btcNoChangeId,ethYesChangeId:$ethYesChangeId,ethNoChangeId:$ethNoChangeId,oracleMinAgeSeconds:$oracleMinAgeSeconds,oracleUpdateIntervalSeconds:$oracleUpdateIntervalSeconds,oracleStaleAfterSeconds:$oracleStaleAfterSeconds}' \
    >"$OUTPUT"
  echo "Wrote $OUTPUT"
fi
