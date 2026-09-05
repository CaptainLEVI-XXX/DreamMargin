#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-demo-markets.json"
MODE="${1:?use create, schedule, or execute}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"

CORE="0x2802504314685D89bF6C992CA5a8e7cC78bc0294"
MODULE="0x3ecC694Cef705358864a646142ac17A90E29e388"
FACTORY="0xE6bEE93cE87c9E6e62aCb621caa7832EE47b4F6B"
ORACLE_HUB="0xe40db387cC98601Dd11bd634fF2f3AD5686dE32b"
COLLATERAL="0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E"
OUTCOME_TOKEN="0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9"
OPEN_POLICY="0xa24822b8d4adcc770c8b071e0dc8e19c39991204"
ZERO="0x0000000000000000000000000000000000000000"
MARKET_TYPE="0x06c65d9f"
ACCOUNT="$(cast wallet address --private-key "$PRIVATE_KEY")"
CONTROLLER="$(jq -r '.controller' "$DEPLOYMENT")"

INTERVAL_SECONDS="${DEMO_MARKET_INTERVAL_SECONDS:-3888000}"
MIN_LIFETIME_SECONDS="${DEMO_MIN_LIFETIME_SECONDS:-2678400}"
SETTLEMENT_WINDOW_SECONDS="${DEMO_SETTLEMENT_WINDOW_SECONDS:-86400}"
CREATOR_FUNDING_WEI="${DEMO_CREATOR_FUNDING_WEI:-34000000000000000000}"
CREATOR_TARGET_BALANCE_WEI="${DEMO_CREATOR_TARGET_BALANCE_WEI:-38000000000000000000}"
REACTIVITY_PRIORITY_FEE="${DEMO_REACTIVITY_PRIORITY_FEE_WEI:-1000000000}"
REACTIVITY_MAX_FEE="${DEMO_REACTIVITY_MAX_FEE_WEI:-10000000000}"
REACTIVITY_GAS_LIMIT="${DEMO_REACTIVITY_GAS_LIMIT:-200000000}"
POLICY_MIN_INTERVAL="${DEMO_POLICY_MIN_INTERVAL_SECONDS:-2678400}"
MIN_AGE="${ORACLE_MIN_AGE_SECONDS:-60}"
UPDATE_INTERVAL="${ORACLE_UPDATE_INTERVAL_SECONDS:-30}"
STALE_AFTER="${ORACLE_STALE_AFTER_SECONDS:-600}"

MARKETS_SIGNATURE='markets(bytes32)(uint256,uint8,uint8,address,uint32,bytes32,address,address,address,address,uint256,uint256,uint64,uint64)'
SCHEDULE_SIGNATURE='scheduleSeriesPolicyChange(bytes32,bytes32,(address,bytes32,uint32,address,uint64,(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),(uint40,uint40,uint40,uint128,uint16,uint16),bool,bool))'
EXECUTE_SIGNATURE='executeSeriesPolicyChange(bytes32,bytes32,(address,bytes32,uint32,address,uint64,(uint256,uint256,uint256,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint40,uint40,uint40,uint16,uint8,uint8),(uint40,uint40,uint40,uint128,uint16,uint16),bool,bool))'
ACTIVATE_SIGNATURE='activateSeriesGeneration((bytes32,address,uint64,address,uint256,address),uint8)'

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

send_checked() {
  local result_name="$1"
  local label="$2"
  shift 2
  local submitted canonical_receipt tx_hash
  if ! submitted="$(cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json 2>&1)"; then
    echo "$label submission failed:" >&2
    echo "$submitted" >&2
    exit 1
  fi
  tx_hash="$(jq -r '.transactionHash' <<<"$submitted")"
  canonical_receipt="$(cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json)"
  if [[ "$(jq -r '.status' <<<"$canonical_receipt")" != "0x1" ]]; then
    echo "$label failed." >&2
    exit 1
  fi
  echo "$label completed ($tx_hash)."
  printf -v "$result_name" '%s' "$canonical_receipt"
}

event_topic() {
  cast keccak "$1"
}

indexed_topic() {
  local receipt="$1"
  local signature="$2"
  local index="$3"
  local topic
  topic="$(lower "$(event_topic "$signature")")"
  jq -r --arg topic "$topic" --argjson index "$index" \
    '.logs[] | select((.topics[0] | ascii_downcase) == $topic) | .topics[$index]' \
    <<<"$receipt" | head -n 1
}

address_from_topic() {
  local topic="$1"
  printf '0x%s' "${topic: -40}"
}

write_manifest() {
  local existing
  existing='{}'
  if [[ -f "$OUTPUT" ]]; then
    existing="$(jq . "$OUTPUT")"
  fi
  jq -n \
    --argjson existing "$existing" \
    --arg schema "dreammargin.shannon-demo-markets.v1" \
    --argjson chainId 50312 \
    --arg owner "$ACCOUNT" \
    --arg operatorId "${operator_id:-}" \
    --arg venueId "${venue_id:-}" \
    --arg creator "${creator:-}" \
    --arg creatorPolicy "${creator_policy:-}" \
    --argjson creatorFunded "${creator_funded:-false}" \
    --argjson venuePolicyUpdated "${venue_policy_updated:-false}" \
    --argjson reactivityConfigured "${reactivity_configured:-false}" \
    --arg btcMarketId "${btc_market_id:-}" \
    --arg ethMarketId "${eth_market_id:-}" \
    --argjson intervalSeconds "$INTERVAL_SECONDS" \
    --argjson minimumLifetimeSeconds "$MIN_LIFETIME_SECONDS" \
    --argjson expectedExpiry "${expected_expiry:-0}" \
    --arg policyId "${policy_id:-}" \
    --arg policyChangeId "${policy_change_id:-}" \
    --arg policyStatus "${policy_status:-unconfigured}" \
    '$existing + {schema:$schema,chainId:$chainId,owner:$owner,operatorId:$operatorId,venueId:$venueId,creator:$creator,creatorPolicy:$creatorPolicy,creatorFunded:$creatorFunded,venuePolicyUpdated:$venuePolicyUpdated,reactivityConfigured:$reactivityConfigured,btcMarketId:$btcMarketId,ethMarketId:$ethMarketId,intervalSeconds:$intervalSeconds,minimumLifetimeSeconds:$minimumLifetimeSeconds,expectedExpiry:$expectedExpiry,dreamMarginPolicyId:$policyId,dreamMarginPolicyChangeId:$policyChangeId,dreamMarginPolicyStatus:$policyStatus}' \
    >"$OUTPUT"
}

load_manifest() {
  if [[ ! -f "$OUTPUT" ]]; then
    echo "Missing $OUTPUT; run create first." >&2
    exit 1
  fi
  operator_id="$(jq -r '.operatorId' "$OUTPUT")"
  venue_id="$(jq -r '.venueId' "$OUTPUT")"
  creator="$(jq -r '.creator' "$OUTPUT")"
  creator_policy="$(jq -r '.creatorPolicy' "$OUTPUT")"
  creator_funded="$(jq -r '.creatorFunded // false' "$OUTPUT")"
  venue_policy_updated="$(jq -r '.venuePolicyUpdated // false' "$OUTPUT")"
  reactivity_configured="$(jq -r '.reactivityConfigured // false' "$OUTPUT")"
  btc_market_id="$(jq -r '.btcMarketId' "$OUTPUT")"
  eth_market_id="$(jq -r '.ethMarketId' "$OUTPUT")"
  expected_expiry="$(jq -r '.expectedExpiry' "$OUTPUT")"
  policy_id="$(jq -r '.dreamMarginPolicyId // empty' "$OUTPUT")"
  policy_change_id="$(jq -r '.dreamMarginPolicyChangeId // empty' "$OUTPUT")"
  policy_status="$(jq -r '.dreamMarginPolicyStatus // "unconfigured"' "$OUTPUT")"
}

validate_lifetime() {
  local now next_boundary
  now="$(date +%s)"
  next_boundary="$(( (now / INTERVAL_SECONDS + 1) * INTERVAL_SECONDS ))"
  if (( next_boundary - now < MIN_LIFETIME_SECONDS )); then
    echo "The next aligned expiry is less than the required minimum lifetime." >&2
    exit 1
  fi
  expected_expiry="$next_boundary"
}

create() {
  if [[ -f "$OUTPUT" ]]; then
    load_manifest
    echo "Resuming the recorded DreamMargin demo-market deployment."
  else
    operator_id="${DEMO_OPERATOR_ID:-}"
    venue_id=""
    creator=""
    creator_policy=""
    creator_funded=false
    venue_policy_updated=false
    reactivity_configured=false
    btc_market_id=""
    eth_market_id=""
    policy_id=""
    policy_change_id=""
    policy_status="unconfigured"
    validate_lifetime
  fi

  local receipt operator_topic venue_topic creator_topic fee_params context
  context="$(cast from-utf8 'DreamMargin demo')"
  if [[ -z "$operator_id" ]]; then
    send_checked receipt "DreamMargin operator registration" "$CORE" \
      'registerOperator(address,bool,address,bytes)(uint32)' "$ACCOUNT" true "$ZERO" "$context"
    operator_topic="$(indexed_topic "$receipt" \
      'OperatorRegistered(uint32,address,address,bool,address,bytes)' 1)"
    operator_id="$(cast to-dec "$operator_topic")"
    write_manifest
  else
    echo "Reusing DreamMargin operator $operator_id."
  fi

  if [[ -z "$venue_id" ]]; then
    fee_params="$(cast abi-encode 'f(uint8,uint64,uint64,uint64,uint64,uint64)' 2 0 0 0 0 0)"
    send_checked receipt "DreamMargin venue creation" "$CORE" \
      'createVenue(uint32,bytes4,(bytes,address,address,address,bool,bytes))(bytes32)' \
      "$operator_id" "$MARKET_TYPE" "($fee_params,$ACCOUNT,$OPEN_POLICY,$ZERO,true,$context)"
    venue_topic="$(indexed_topic "$receipt" \
      'VenueCreated(uint32,bytes32,bytes4,bytes,address,address,address,bool,bytes)' 2)"
    venue_id="$venue_topic"
    write_manifest
  else
    echo "Reusing DreamMargin venue $venue_id."
  fi

  if [[ -z "$creator" ]]; then
    send_checked receipt "DreamMargin MarketCreator deployment" "$FACTORY" \
      'createMarketCreator(address,address,address,uint32,bytes32,(uint256,uint256,uint256))(address,address)' \
      "$ACCOUNT" "$MODULE" "$ORACLE_HUB" "$operator_id" "$venue_id" '(1000,1000,1000)'
    creator_topic="$(indexed_topic "$receipt" \
      'MarketCreatorCreated(address,address,uint32,bytes32,address,address,address)' 1)"
    creator="$(address_from_topic "$creator_topic")"
    creator_policy="$(cast abi-decode 'f()(bytes32,address,address,address)' \
      "$(jq -r '.logs[] | select((.topics[0] | ascii_downcase) == "'"$(lower "$(event_topic 'MarketCreatorCreated(address,address,uint32,bytes32,address,address,address)')")"'") | .data' <<<"$receipt")" | sed -n '2p')"
    write_manifest
  else
    echo "Reusing MarketCreator $creator."
  fi

  if [[ "$creator_funded" != "true" ]]; then
    send_checked receipt "MarketCreator funding" "$creator" --value "$CREATOR_FUNDING_WEI"
    creator_funded=true
    write_manifest
  fi
  local creator_balance top_up
  creator_balance="$(cast balance "$creator" --rpc-url "$RPC_URL")"
  if (( creator_balance < CREATOR_TARGET_BALANCE_WEI )); then
    top_up="$((CREATOR_TARGET_BALANCE_WEI - creator_balance))"
    send_checked receipt "MarketCreator balance top-up" "$creator" --value "$top_up"
  fi

  if [[ "$venue_policy_updated" != "true" ]]; then
    fee_params="$(cast abi-encode 'f(uint8,uint64,uint64,uint64,uint64,uint64)' 2 0 0 0 0 0)"
    send_checked receipt "DreamMargin venue policy binding" "$CORE" \
      'updateVenue(uint32,bytes32,(bytes,address,address,address,bool,bytes))' \
      "$operator_id" "$venue_id" \
      "($fee_params,$ACCOUNT,$creator_policy,$ZERO,true,$context)"
    venue_policy_updated=true
    write_manifest
  fi

  if [[ "$reactivity_configured" != "true" ]]; then
    send_checked receipt "MarketCreator Reactivity configuration" "$creator" \
      'setReactivityGasParams(uint64,uint64,uint64)' \
      "$REACTIVITY_PRIORITY_FEE" "$REACTIVITY_MAX_FEE" "$REACTIVITY_GAS_LIMIT"
    reactivity_configured=true
    write_manifest
  fi

  if [[ -z "$btc_market_id" ]]; then
    send_checked receipt "BTC demo-series registration" "$creator" \
      'registerSeries(uint32,(address,string,uint64,uint64,uint64))' \
      1 "($COLLATERAL,BTC,8,$INTERVAL_SECONDS,$SETTLEMENT_WINDOW_SECONDS)"
    send_checked receipt "BTC demo-market roll" "$creator" 'triggerRoll(uint32)' 1
    btc_market_id="$(indexed_topic "$receipt" \
      'MarketCreated(bytes32,address,address,uint256,uint256,address,string,uint256,uint64,uint64,uint256,string,uint64)' 1)"
    write_manifest
  fi
  if [[ -z "$eth_market_id" ]]; then
    send_checked receipt "ETH demo-series registration" "$creator" \
      'registerSeries(uint32,(address,string,uint64,uint64,uint64))' \
      2 "($COLLATERAL,ETH,8,$INTERVAL_SECONDS,$SETTLEMENT_WINDOW_SECONDS)"
    send_checked receipt "ETH demo-market roll" "$creator" 'triggerRoll(uint32)' 2
    eth_market_id="$(indexed_topic "$receipt" \
      'MarketCreated(bytes32,address,address,uint256,uint256,address,string,uint256,uint64,uint64,uint256,string,uint64)' 1)"
    write_manifest
  fi

  policy_id="$(cast keccak "$(cast abi-encode 'f(string,address)' 'DREAMMARGIN_DEMO_SERIES_V1' "$creator")")"
  policy_change_id="$(cast keccak "$(cast abi-encode 'f(string,bytes32)' 'REGISTER_DEMO_SERIES_POLICY_V1' "$policy_id")")"
  policy_status="${policy_status:-unconfigured}"
  write_manifest
  echo "Created BTC and ETH demo markets expiring at $expected_expiry."
  echo "Wrote $OUTPUT"
}

policy_tuple() {
  local risk oracle
  risk='(100000000,300000000,500000000,1000000,6000,7500,8000,500,1000,1000,10000,20000,1200,600,3600,4,6,0)'
  oracle="($MIN_AGE,$UPDATE_INTERVAL,$STALE_AFTER,20000000,16,4)"
  printf '(%s,%s,%s,%s,%s,%s,%s,true,false)' \
    "$creator" "$venue_id" "$operator_id" "$COLLATERAL" "$POLICY_MIN_INTERVAL" "$risk" "$oracle"
}

schedule_policy() {
  load_manifest
  if [[ "$policy_status" != "unconfigured" ]]; then
    echo "Demo series policy is already $policy_status."
    exit 0
  fi
  local receipt tuple
  tuple="$(policy_tuple)"
  send_checked receipt "Demo series policy schedule" "$CONTROLLER" "$SCHEDULE_SIGNATURE" \
    "$policy_change_id" "$policy_id" "$tuple"
  policy_status="scheduled"
  write_manifest
}

generation_key() {
  local encoded
  encoded="$(cast abi-encode 'f(bytes32,address,uint64,address,uint256,address)' \
    "$1" "$2" "$3" "$OUTCOME_TOKEN" "$4" "$COLLATERAL")"
  cast keccak "$encoded"
}

activate_market() {
  local market_id="$1"
  local record pool yes_id no_id nonce expiry interval yes_key no_key receipt
  record="$(cast call "$MODULE" "$MARKETS_SIGNATURE" "$market_id" --rpc-url "$RPC_URL" --json)"
  pool="$(jq -r '.[9]' <<<"$record")"
  yes_id="$(jq -r '.[10]' <<<"$record")"
  no_id="$(jq -r '.[11]' <<<"$record")"
  nonce="$(cast call "$MODULE" 'marketNonce(bytes32)(uint64)' "$market_id" --rpc-url "$RPC_URL")"
  expiry="$(jq -r '.[13]' <<<"$record")"
  interval="$((expiry - $(jq -r '.[12]' <<<"$record")))"
  if (( expiry - $(date +%s) < MIN_LIFETIME_SECONDS || interval < POLICY_MIN_INTERVAL )); then
    echo "Demo market $market_id does not satisfy the one-month lifetime policy." >&2
    exit 1
  fi
  yes_key="$(generation_key "$market_id" "$pool" "$nonce" "$yes_id")"
  no_key="$(generation_key "$market_id" "$pool" "$nonce" "$no_id")"
  send_checked receipt "YES generation activation" "$CONTROLLER" "$ACTIVATE_SIGNATURE" \
    "($market_id,$pool,$nonce,$OUTCOME_TOKEN,$yes_id,$COLLATERAL)" 0
  send_checked receipt "NO generation activation" "$CONTROLLER" "$ACTIVATE_SIGNATURE" \
    "($market_id,$pool,$nonce,$OUTCOME_TOKEN,$no_id,$COLLATERAL)" 1
  printf '%s %s %s %s %s %s\n' "$pool" "$nonce" "$yes_id" "$no_id" "$yes_key" "$no_key"
}

execute_policy() {
  load_manifest
  if [[ "$policy_status" == "active" ]]; then
    echo "Demo series policy and generations are already active."
    exit 0
  fi
  local receipt tuple btc_data eth_data btc_line eth_line
  local btc_pool btc_nonce btc_yes_id btc_no_id btc_yes_key btc_no_key
  local eth_pool eth_nonce eth_yes_id eth_no_id eth_yes_key eth_no_key
  tuple="$(policy_tuple)"
  send_checked receipt "Demo series policy execution" "$CONTROLLER" "$EXECUTE_SIGNATURE" \
    "$policy_change_id" "$policy_id" "$tuple"
  btc_data="$(activate_market "$btc_market_id")"
  eth_data="$(activate_market "$eth_market_id")"
  btc_line="${btc_data##*$'\n'}"
  eth_line="${eth_data##*$'\n'}"
  read -r btc_pool btc_nonce btc_yes_id btc_no_id btc_yes_key btc_no_key <<<"$btc_line"
  read -r eth_pool eth_nonce eth_yes_id eth_no_id eth_yes_key eth_no_key <<<"$eth_line"
  policy_status="active"
  write_manifest
  jq --argjson configuredAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
    --arg btcData "$btc_data" --arg ethData "$eth_data" \
    --arg btcPool "$btc_pool" --argjson btcMarketNonce "$btc_nonce" \
    --arg btcYesId "$btc_yes_id" --arg btcNoId "$btc_no_id" \
    --arg btcYesGenerationKey "$btc_yes_key" --arg btcNoGenerationKey "$btc_no_key" \
    --arg ethPool "$eth_pool" --argjson ethMarketNonce "$eth_nonce" \
    --arg ethYesId "$eth_yes_id" --arg ethNoId "$eth_no_id" \
    --arg ethYesGenerationKey "$eth_yes_key" --arg ethNoGenerationKey "$eth_no_key" \
    '. + {configuredAtBlock:$configuredAtBlock,btcPool:$btcPool,btcMarketNonce:$btcMarketNonce,btcYesId:$btcYesId,btcNoId:$btcNoId,btcYesGenerationKey:$btcYesGenerationKey,btcNoGenerationKey:$btcNoGenerationKey,ethPool:$ethPool,ethMarketNonce:$ethMarketNonce,ethYesId:$ethYesId,ethNoId:$ethNoId,ethYesGenerationKey:$ethYesGenerationKey,ethNoGenerationKey:$ethNoGenerationKey,btcActivation:$btcData,ethActivation:$ethData}' \
    "$OUTPUT" >"$OUTPUT.tmp"
  mv "$OUTPUT.tmp" "$OUTPUT"
  echo "Demo series policy and four outcome generations are active."
}

case "$MODE" in
  create) create ;;
  schedule) schedule_policy ;;
  execute) execute_policy ;;
  *) echo "Usage: $0 {create|schedule|execute}" >&2; exit 1 ;;
esac
