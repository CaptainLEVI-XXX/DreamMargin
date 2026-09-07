#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
MARKETS="$CONTRACTS_DIR/deployments/shannon-demo-markets.json"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-demo-liquidity.json"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"

COLLATERAL="0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E"
OUTCOME_TOKEN="0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9"
ACCOUNT="$(cast wallet address --private-key "$PRIVATE_KEY")"
VAULT="$(jq -r '.vault' "$DEPLOYMENT")"
VAULT_TARGET="${DEMO_VAULT_TARGET:-50000000000}"
BOOK_QUANTITY="${DEMO_BOOK_QUANTITY:-50000000000}"
ORACLE_DEPTH="${DEMO_ORACLE_DEPTH:-25000000000}"
FAUCET_CHUNK="${DEMO_FAUCET_CHUNK:-10000000000}"
YES_BID="${DEMO_YES_BID:-450000}"
YES_ASK="${DEMO_YES_ASK:-550000}"
MINIMUM_HEADROOM="${DEMO_MIN_LIFETIME_SECONDS:-2678400}"
MARKETS_SIGNATURE='markets(bytes32)(uint256,uint8,uint8,address,uint32,bytes32,address,address,address,address,uint256,uint256,uint64,uint64)'
ORDER_SIGNATURE='placeBinaryOrder(uint8,uint256,uint256,uint64,uint8,uint8,address,uint96,uint64)(bool,uint128)'

send_checked() {
  local result_name="$1"
  local label="$2"
  shift 2
  local submitted receipt tx_hash
  if ! submitted="$(cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json 2>&1)"; then
    echo "$label submission failed:" >&2
    echo "$submitted" >&2
    exit 1
  fi
  tx_hash="$(jq -r '.transactionHash' <<<"$submitted")"
  receipt="$(cast receipt "$tx_hash" --rpc-url "$RPC_URL" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "$label failed ($tx_hash)." >&2
    exit 1
  fi
  printf -v "$result_name" '%s' "$tx_hash"
  echo "$label completed ($tx_hash)."
}

market_record() {
  cast call 0x3ecC694Cef705358864a646142ac17A90E29e388 \
    "$MARKETS_SIGNATURE" "$1" --rpc-url "$RPC_URL" --json
}

book() {
  cast call "$1" 'getBookLevels(bool,uint64)((uint256,uint256)[])' \
    "$2" 1 --rpc-url "$RPC_URL" --json
}

uint_call() {
  local output
  output="$(cast call "$@" --rpc-url "$RPC_URL")"
  printf '%s' "${output%% *}"
}

ensure_collateral() {
  local target="$1"
  local balance deficit amount faucet_tx
  balance="$(uint_call "$COLLATERAL" 'balanceOf(address)(uint256)' "$ACCOUNT")"
  while (( balance < target )); do
    deficit="$((target - balance))"
    amount="$deficit"
    if (( amount > FAUCET_CHUNK )); then
      amount="$FAUCET_CHUNK"
    fi
    send_checked faucet_tx "Demo tUSDC faucet" "$COLLATERAL" 'faucet(uint256)' "$amount"
    balance="$(uint_call "$COLLATERAL" 'balanceOf(address)(uint256)' "$ACCOUNT")"
  done
}

seed_market() {
  local symbol="$1"
  local market_id="$2"
  local record pool yes_id no_id expiry expiry_ns bids asks bid_depth ask_depth
  local bid_deficit ask_deficit yes_balance no_balance yes_needed no_needed mint_amount
  local collateral_approve_tx mint_tx yes_approve_tx no_approve_tx ask_tx bid_tx
  record="$(market_record "$market_id")"
  pool="$(jq -r '.[9]' <<<"$record")"
  yes_id="$(jq -r '.[10]' <<<"$record")"
  no_id="$(jq -r '.[11]' <<<"$record")"
  expiry="$(jq -r '.[13]' <<<"$record")"
  if (( expiry - $(date +%s) < MINIMUM_HEADROOM )); then
    echo "$symbol market has less than one month remaining." >&2
    exit 1
  fi
  bids="$(book "$pool" true)"
  asks="$(book "$pool" false)"
  bid_depth=0
  ask_depth=0
  if (( $(jq -r '.[0] | length' <<<"$bids") != 0 )); then
    if (( $(jq -r '.[0][0][0]' <<<"$bids") != YES_BID )); then
      echo "$symbol best bid is not the configured demo price." >&2
      exit 1
    fi
    bid_depth="$(jq -r '.[0][0][1]' <<<"$bids")"
  fi
  if (( $(jq -r '.[0] | length' <<<"$asks") != 0 )); then
    if (( $(jq -r '.[0][0][0]' <<<"$asks") != YES_ASK )); then
      echo "$symbol best ask is not the configured demo price." >&2
      exit 1
    fi
    ask_depth="$(jq -r '.[0][0][1]' <<<"$asks")"
  fi
  bid_deficit=0
  ask_deficit=0
  if (( bid_depth < BOOK_QUANTITY )); then
    bid_deficit="$((BOOK_QUANTITY - bid_depth))"
  fi
  if (( ask_depth < BOOK_QUANTITY )); then
    ask_deficit="$((BOOK_QUANTITY - ask_depth))"
  fi
  if (( bid_deficit == 0 && ask_deficit == 0 )); then
    echo "$symbol book already meets the configured depth."
    return
  fi

  expiry_ns="$(uint_call "$pool" 'marketExpiryNs()(uint64)')"
  yes_balance="$(uint_call "$OUTCOME_TOKEN" 'balanceOf(address,uint256)(uint256)' "$ACCOUNT" "$yes_id")"
  no_balance="$(uint_call "$OUTCOME_TOKEN" 'balanceOf(address,uint256)(uint256)' "$ACCOUNT" "$no_id")"
  yes_needed=0
  no_needed=0
  if (( yes_balance < ask_deficit )); then
    yes_needed="$((ask_deficit - yes_balance))"
  fi
  if (( no_balance < bid_deficit )); then
    no_needed="$((bid_deficit - no_balance))"
  fi
  mint_amount="$yes_needed"
  if (( no_needed > mint_amount )); then
    mint_amount="$no_needed"
  fi
  if (( mint_amount != 0 )); then
    ensure_collateral "$mint_amount"
    send_checked collateral_approve_tx "$symbol collateral approval" "$COLLATERAL" \
      'approve(address,uint256)(bool)' "$pool" "$mint_amount"
    send_checked mint_tx "$symbol complete-set mint" "$pool" \
      'mintSet(address,address,uint256)' "$ACCOUNT" "$ACCOUNT" "$mint_amount"
  else
    echo "$symbol complete-set inventory is already available; reusing it."
  fi
  if (( ask_deficit != 0 )); then
    send_checked yes_approve_tx "$symbol YES approval" "$OUTCOME_TOKEN" \
      'approve(address,uint256,uint256)(bool)' "$pool" "$yes_id" "$ask_deficit"
    send_checked ask_tx "$symbol 0.55 YES ask" "$pool" "$ORDER_SIGNATURE" \
      1 "$YES_ASK" "$ask_deficit" "$expiry_ns" 0 0 \
      0x0000000000000000000000000000000000000000 0 0
  fi
  if (( bid_deficit != 0 )); then
    send_checked no_approve_tx "$symbol NO approval" "$OUTCOME_TOKEN" \
      'approve(address,uint256,uint256)(bool)' "$pool" "$no_id" "$bid_deficit"
    send_checked bid_tx "$symbol 0.45 YES bid" "$pool" "$ORDER_SIGNATURE" \
      3 "$YES_BID" "$bid_deficit" "$expiry_ns" 0 0 \
      0x0000000000000000000000000000000000000000 0 0
  fi
}

if [[ "$(printf '%s' "$ACCOUNT" | tr '[:upper:]' '[:lower:]')" != \
  "$(jq -r '.deployer' "$DEPLOYMENT" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "PRIVATE_KEY does not match the deployment owner." >&2
  exit 1
fi

vault_assets="$(uint_call "$VAULT" 'totalAssets()(uint256)')"
deposit_tx="not-required"
if (( vault_assets < VAULT_TARGET )); then
  deposit_amount="$((VAULT_TARGET - vault_assets))"
  ensure_collateral "$deposit_amount"
  send_checked vault_approve_tx "Vault collateral approval" "$COLLATERAL" \
    'approve(address,uint256)(bool)' "$VAULT" "$deposit_amount"
  send_checked deposit_tx "DreamMargin vault funding" "$VAULT" \
    'deposit(uint256,address)(uint256)' "$deposit_amount" "$ACCOUNT"
fi

btc_market_id="$(jq -r '.btcMarketId' "$MARKETS")"
eth_market_id="$(jq -r '.ethMarketId' "$MARKETS")"
seed_market BTC "$btc_market_id"
seed_market ETH "$eth_market_id"

btc_record="$(market_record "$btc_market_id")"
eth_record="$(market_record "$eth_market_id")"
btc_pool="$(jq -r '.[9]' <<<"$btc_record")"
eth_pool="$(jq -r '.[9]' <<<"$eth_record")"
btc_bid="$(book "$btc_pool" true)"
btc_ask="$(book "$btc_pool" false)"
eth_bid="$(book "$eth_pool" true)"
eth_ask="$(book "$eth_pool" false)"
vault_assets="$(uint_call "$VAULT" 'totalAssets()(uint256)')"

for depth in \
  "$(jq -r '.[0][0][1]' <<<"$btc_bid")" \
  "$(jq -r '.[0][0][1]' <<<"$btc_ask")" \
  "$(jq -r '.[0][0][1]' <<<"$eth_bid")" \
  "$(jq -r '.[0][0][1]' <<<"$eth_ask")"; do
  if (( depth < ORACLE_DEPTH )); then
    echo "A seeded book side is below DreamMargin's configured oracle depth." >&2
    exit 1
  fi
done

jq -n \
  --arg schema dreammargin.shannon-demo-liquidity.v1 \
  --argjson chainId 50312 \
  --argjson seededAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
  --arg account "$ACCOUNT" --arg vault "$VAULT" --argjson vaultAssets "$vault_assets" \
  --arg depositTransaction "$deposit_tx" \
  --arg btcMarketId "$btc_market_id" --arg btcPool "$btc_pool" \
  --argjson btcBestBid "$(jq -r '.[0][0][0]' <<<"$btc_bid")" \
  --argjson btcBestAsk "$(jq -r '.[0][0][0]' <<<"$btc_ask")" \
  --argjson btcBidDepth "$(jq -r '.[0][0][1]' <<<"$btc_bid")" \
  --argjson btcAskDepth "$(jq -r '.[0][0][1]' <<<"$btc_ask")" \
  --arg ethMarketId "$eth_market_id" --arg ethPool "$eth_pool" \
  --argjson ethBestBid "$(jq -r '.[0][0][0]' <<<"$eth_bid")" \
  --argjson ethBestAsk "$(jq -r '.[0][0][0]' <<<"$eth_ask")" \
  --argjson ethBidDepth "$(jq -r '.[0][0][1]' <<<"$eth_bid")" \
  --argjson ethAskDepth "$(jq -r '.[0][0][1]' <<<"$eth_ask")" \
  '{schema:$schema,chainId:$chainId,seededAtBlock:$seededAtBlock,account:$account,vault:$vault,vaultAssets:$vaultAssets,depositTransaction:$depositTransaction,btc:{marketId:$btcMarketId,pool:$btcPool,bestBid:$btcBestBid,bestAsk:$btcBestAsk,bidDepth:$btcBidDepth,askDepth:$btcAskDepth},eth:{marketId:$ethMarketId,pool:$ethPool,bestBid:$ethBestBid,bestAsk:$ethBestAsk,bidDepth:$ethBidDepth,askDepth:$ethAskDepth}}' \
  >"$OUTPUT"

echo "DreamMargin demo vault and both long-lived books are ready."
echo "Wrote $OUTPUT"
