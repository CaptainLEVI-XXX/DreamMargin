#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
MARKETS="$CONTRACTS_DIR/deployments/shannon-demo-markets.json"
PRECOMPILE="0x0000000000000000000000000000000000000100"
SUBSCRIBE_SIGNATURE='subscribe((bytes32[4],address,address,address,address,bytes4,uint64,uint64,uint64,bool,bool))(uint256)'
UNSUBSCRIBE_SIGNATURE='unsubscribe(uint256)'
ZERO="0x0000000000000000000000000000000000000000"
ZERO_TOPIC="0x0000000000000000000000000000000000000000000000000000000000000000"
CALLBACK_SELECTOR="0x53edf33d"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"
ACCOUNT="$(cast wallet address --private-key "$PRIVATE_KEY")"
ORACLE="$(jq -r '.oracle' "$DEPLOYMENT")"
BTC_POOL="$(jq -r '.btcPool' "$MARKETS")"
ETH_POOL="$(jq -r '.ethPool' "$MARKETS")"
BTC_YES_KEY="$(jq -r '.btcYesGenerationKey' "$MARKETS")"
BTC_NO_KEY="$(jq -r '.btcNoGenerationKey' "$MARKETS")"
ETH_YES_KEY="$(jq -r '.ethYesGenerationKey' "$MARKETS")"
ETH_NO_KEY="$(jq -r '.ethNoGenerationKey' "$MARKETS")"
OBSERVER="$(jq -r '.reactiveObserver // empty' "$MARKETS")"
BTC_SUBSCRIPTION_ID="$(jq -r '.btcSubscriptionId // 0' "$MARKETS")"
ETH_SUBSCRIPTION_ID="$(jq -r '.ethSubscriptionId // 0' "$MARKETS")"

if [[ -n "$OBSERVER" ]]; then
  bound_oracle="$(cast call "$OBSERVER" 'ORACLE()(address)' --rpc-url "$RPC_URL" 2>/dev/null || true)"
  if [[ "$(printf '%s' "$bound_oracle" | tr '[:upper:]' '[:lower:]')" != \
    "$(printf '%s' "$ORACLE" | tr '[:upper:]' '[:lower:]')" ]]; then
    for subscription_id in "$BTC_SUBSCRIPTION_ID" "$ETH_SUBSCRIPTION_ID"; do
      if (( subscription_id != 0 )); then
        receipt="$(cast send "$PRECOMPILE" "$UNSUBSCRIBE_SIGNATURE" "$subscription_id" \
          --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
        if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
          echo "Could not retire stale Reactivity subscription $subscription_id." >&2
          exit 1
        fi
        echo "Retired stale Reactivity subscription $subscription_id."
      fi
    done
    OBSERVER=""
    BTC_SUBSCRIPTION_ID=0
    ETH_SUBSCRIPTION_ID=0
  fi
fi

minimum_balance="32000000000000000000"
owner_balance="$(cast balance "$ACCOUNT" --rpc-url "$RPC_URL" | awk '{print $1}')"
if (( ${#owner_balance} < ${#minimum_balance} )) \
  || { (( ${#owner_balance} == ${#minimum_balance} )) && [[ "$owner_balance" < "$minimum_balance" ]]; }; then
  echo "The subscription owner needs at least 32 STT; fund $ACCOUNT before continuing." >&2
  exit 1
fi

if [[ -z "$OBSERVER" ]]; then
  deployment_result="$(forge create \
    src/oracle/DreamMarginReactiveObserver.sol:DreamMarginReactiveObserver \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --json \
    --constructor-args \
    "$ORACLE" "$BTC_POOL" "$BTC_YES_KEY" "$BTC_NO_KEY" \
    "$ETH_POOL" "$ETH_YES_KEY" "$ETH_NO_KEY")"
  OBSERVER="$(jq -r '.deployedTo' <<<"$deployment_result")"
  echo "Reactive observer deployed at $OBSERVER."
fi

subscribe_pool() {
  local result_name="$1"
  local symbol="$2"
  local pool="$3"
  local receipt topic subscription_id
  receipt="$(cast send "$PRECOMPILE" "$SUBSCRIBE_SIGNATURE" \
    "([$ZERO_TOPIC,$ZERO_TOPIC,$ZERO_TOPIC,$ZERO_TOPIC],$ZERO,$ZERO,$pool,$OBSERVER,$CALLBACK_SELECTOR,1000000000,10000000000,20000000,true,true)" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "$symbol Reactivity subscription reverted." >&2
    exit 1
  fi
  topic="$(jq -r '.logs[] | select((.address | ascii_downcase) == "0x0000000000000000000000000000000000000100") | .topics[1]' <<<"$receipt" | head -n 1)"
  subscription_id="$(cast to-dec "$topic")"
  printf -v "$result_name" '%s' "$subscription_id"
  echo "$symbol Reactivity subscription $subscription_id is active."
}

if (( BTC_SUBSCRIPTION_ID == 0 )); then
  subscribe_pool BTC_SUBSCRIPTION_ID BTC "$BTC_POOL"
fi
if (( ETH_SUBSCRIPTION_ID == 0 )); then
  subscribe_pool ETH_SUBSCRIPTION_ID ETH "$ETH_POOL"
fi

jq \
  --arg observer "$OBSERVER" \
  --arg observerOracle "$ORACLE" \
  --argjson btcSubscriptionId "$BTC_SUBSCRIPTION_ID" \
  --argjson ethSubscriptionId "$ETH_SUBSCRIPTION_ID" \
  '.reactiveObserver = $observer | .reactiveObserverOracle = $observerOracle | .btcSubscriptionId = $btcSubscriptionId | .ethSubscriptionId = $ethSubscriptionId' \
  "$MARKETS" >"$MARKETS.tmp"
mv "$MARKETS.tmp" "$MARKETS"

echo "Backend-free pool-triggered oracle updates are configured."
