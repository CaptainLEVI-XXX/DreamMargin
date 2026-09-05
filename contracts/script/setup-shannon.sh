#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
MODE="${1:-all}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE; copy .env.example and configure it." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY in the ignored .env file}"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"

for tool in cast forge jq; do
  command -v "$tool" >/dev/null || { echo "Missing required command: $tool" >&2; exit 1; }
done

choose_rpc() {
  if cast chain-id --rpc-url "$SOMNIA_RPC_URL" >/dev/null 2>&1; then
    RPC_URL="$SOMNIA_RPC_URL"
  elif [[ -n "${SOMNIA_FALLBACK_RPC_URL:-}" ]] && \
    cast chain-id --rpc-url "$SOMNIA_FALLBACK_RPC_URL" >/dev/null 2>&1; then
    RPC_URL="$SOMNIA_FALLBACK_RPC_URL"
  else
    echo "Neither configured Shannon RPC is reachable." >&2
    exit 1
  fi
  if [[ "$(cast chain-id --rpc-url "$RPC_URL")" != "50312" ]]; then
    echo "Configured RPC is not Somnia Shannon (chain ID 50312)." >&2
    exit 1
  fi
}

preflight() {
  choose_rpc
  local account balance
  account="$(cast wallet address --private-key "$PRIVATE_KEY")"
  balance="$(cast balance "$account" --rpc-url "$RPC_URL")"
  if [[ "$balance" == "0" ]]; then
    echo "Deployment wallet $account has no Shannon gas token." >&2
    exit 1
  fi
  echo "Shannon preflight passed for $account (native balance: $balance wei)."
}

discover() {
  "$SCRIPT_DIR/discover-shannon-markets.sh"
}

deploy() {
  RPC_URL="$RPC_URL" "$SCRIPT_DIR/deploy-shannon.sh"
}

schedule() {
  RPC_URL="$RPC_URL" "$SCRIPT_DIR/configure-shannon.sh" schedule
}

execute() {
  RPC_URL="$RPC_URL" "$SCRIPT_DIR/configure-shannon.sh" execute
}

observe() {
  RPC_URL="$RPC_URL" "$SCRIPT_DIR/observe-shannon.sh"
}

smoke() {
  RPC_URL="$RPC_URL" "$SCRIPT_DIR/smoke-shannon.sh"
}

plan() {
  discover
  forge create script/DeployShannon.s.sol:ShannonTransientProbe \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json >/dev/null
  forge build >/dev/null
  echo "Compilation and direct-deployment estimation completed. No transaction was broadcast."
}

cd "$CONTRACTS_DIR"
preflight

case "$MODE" in
  discover) discover ;;
  plan) plan ;;
  deploy) deploy ;;
  schedule) schedule ;;
  execute) execute ;;
  observe) observe ;;
  maintain)
    discover
    execute
    observe
    ;;
  smoke) smoke ;;
  verify) "$SCRIPT_DIR/verify-shannon.sh" ;;
  all)
    discover
    deploy
    schedule
    governance_delay="${GOVERNANCE_DELAY_SECONDS:-60}"
    echo "Waiting $((governance_delay + 5)) seconds for delayed governance."
    sleep "$((governance_delay + 5))"
    execute
    observe
    oracle_age="${ORACLE_MIN_AGE_SECONDS:-60}"
    echo "Waiting $((oracle_age + 5)) seconds for a mature oracle window."
    sleep "$((oracle_age + 5))"
    observe
    smoke
    if [[ "${VERIFY_CONTRACTS:-0}" == "1" ]]; then
      "$SCRIPT_DIR/verify-shannon.sh"
    fi
    ;;
  *)
    echo "Usage: $0 {all|plan|discover|deploy|schedule|execute|observe|maintain|smoke|verify}" >&2
    exit 1
    ;;
esac
