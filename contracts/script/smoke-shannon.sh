#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
MARKETS="${MARKETS:-$CONTRACTS_DIR/deployments/shannon-demo-markets.json}"
OUTPUT="${SMOKE_OUTPUT:-$CONTRACTS_DIR/deployments/shannon-smoke.json}"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"
ACCOUNT="$(cast wallet address --private-key "$PRIVATE_KEY")"
CONTROLLER="$(jq -r '.controller' "$DEPLOYMENT")"
VAULT="$(jq -r '.vault' "$DEPLOYMENT")"
ORACLE="$(jq -r '.oracle' "$DEPLOYMENT")"
COLLATERAL="0x70a86D8842FB63C4Ad2b7cdddF530eBf1BB25d8E"
OUTCOME_TOKEN="0xB52c5934113Af5c0Bb20eb3C72290C8215f755b9"
UNIT=1000000
FAUCET_TARGET=1500000000
VAULT_DEPOSIT=100000000
TARGET_SHARES=500000000
MAX_USER_COLLATERAL=300000000
MAX_DEBT=250000000
PARTIAL_REPAY=250000
CONTROLLER_ALLOWANCE="$((2 * MAX_USER_COLLATERAL + 2 * PARTIAL_REPAY))"
POSITION_OPENED_TOPIC="$(cast keccak 'PositionOpened(uint256,address,bytes32,uint256,uint256,uint256)')"

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

number_call() {
  cast call "$1" "$2" "${@:3}" --rpc-url "$RPC_URL" | awk 'NR == 1 {print $1}'
}

send_call() {
  local result_var="$1"
  shift
  local receipt tx_hash
  receipt="$(cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "Transaction reverted: $*" >&2
    exit 1
  fi
  tx_hash="$(jq -r '.transactionHash' <<<"$receipt")"
  printf -v "$result_var" '%s' "$tx_hash"
  SEND_RECEIPT="$receipt"
}

balance="$(number_call "$COLLATERAL" 'balanceOf(address)(uint256)' "$ACCOUNT")"
if (( balance < FAUCET_TARGET )); then
  send_call faucet_tx "$COLLATERAL" 'faucet(uint256)' "$((FAUCET_TARGET - balance))"
  echo "Funded the smoke wallet with test-only tUSDC ($faucet_tx)."
else
  faucet_tx="not-required"
fi

vault_shares_before="$(number_call "$VAULT" 'balanceOf(address)(uint256)' "$ACCOUNT")"
send_call approve_vault_tx "$COLLATERAL" 'approve(address,uint256)' "$VAULT" "$VAULT_DEPOSIT"
send_call deposit_tx "$VAULT" 'deposit(uint256,address)' "$VAULT_DEPOSIT" "$ACCOUNT"
send_call clear_vault_tx "$COLLATERAL" 'approve(address,uint256)' "$VAULT" 0
vault_shares_after="$(number_call "$VAULT" 'balanceOf(address)(uint256)' "$ACCOUNT")"
smoke_vault_shares="$((vault_shares_after - vault_shares_before))"
if (( smoke_vault_shares == 0 )); then
  echo "Vault deposit minted no ERC-4626 shares." >&2
  exit 1
fi
echo "Deposited tUSDC and received $smoke_vault_shares new vault shares."

send_call controller_approval_tx "$COLLATERAL" \
  'approve(address,uint256)' "$CONTROLLER" "$CONTROLLER_ALLOWANCE"

exercise_market() {
  local prefix="$1"
  local yes_key outcome outcome_index generation_key outcome_id limit_price
  local pool market_id nonce book_side close_book_side book close_book tuple deadline
  local close_limit_price event_log position_topic decoded position
  yes_key="$(jq -r ".${prefix}YesGenerationKey" "$MARKETS")"
  pool="$(jq -r ".${prefix}Pool" "$MARKETS")"
  market_id="$(jq -r ".${prefix}MarketId" "$MARKETS")"
  nonce="$(jq -r ".${prefix}MarketNonce" "$MARKETS")"
  outcome=yes
  outcome_index=0
  generation_key="$yes_key"
  outcome_id="$(jq -r ".${prefix}YesId" "$MARKETS")"
  book_side=false
  close_book_side=true

  book="$(cast call "$pool" 'getBookLevels(bool,uint64)((uint256,uint256)[])' \
    "$book_side" 1 --rpc-url "$RPC_URL")"
  limit_price="$(sed -n 's/^[(]*\[*(\([0-9]*\).*/\1/p' <<<"$book")"
  if [[ -z "$limit_price" ]]; then
    echo "Could not read the $prefix $outcome execution price." >&2
    exit 1
  fi
  deadline="$(( $(date +%s) + 120 ))"
  tuple="(($market_id,$pool,$nonce,$OUTCOME_TOKEN,$outcome_id,$COLLATERAL),$outcome_index,$TARGET_SHARES,20000,$MAX_USER_COLLATERAL,$MAX_DEBT,$limit_price,$deadline)"
  send_call open_tx "$CONTROLLER" \
    'openFromCollateral(((bytes32,address,uint64,address,uint256,address),uint8,uint256,uint32,uint256,uint256,uint256,uint256))' \
    "$tuple"
  event_log="$(jq -c --arg topic "$(lower "$POSITION_OPENED_TOPIC")" \
    '.logs[] | select((.topics[0] | ascii_downcase) == $topic)' <<<"$SEND_RECEIPT")"
  if [[ -z "$event_log" ]]; then
    echo "PositionOpened event missing for $prefix." >&2
    exit 1
  fi
  position_topic="$(jq -r '.topics[1]' <<<"$event_log")"
  position_id="$(cast to-dec "$position_topic")"
  decoded="$(cast decode-abi 'f()(uint256,uint256,uint256)' "$(jq -r '.data' <<<"$event_log")")"
  shares_bought="$(awk 'NR == 2 {print $1}' <<<"$decoded")"
  opening_debt="$(awk 'NR == 3 {print $1}' <<<"$decoded")"

  send_call repay_tx "$CONTROLLER" 'repay(uint256,uint256)' "$position_id" "$PARTIAL_REPAY"
  close_book="$(cast call "$pool" 'getBookLevels(bool,uint64)((uint256,uint256)[])' \
    "$close_book_side" 1 --rpc-url "$RPC_URL")"
  close_limit_price="$(sed -n 's/^[(]*\[*(\([0-9]*\).*/\1/p' <<<"$close_book")"
  if [[ -z "$close_limit_price" ]]; then
    echo "Could not read the $prefix $outcome close price." >&2
    exit 1
  fi
  deadline="$(( $(date +%s) + 120 ))"
  send_call close_tx "$CONTROLLER" \
    'close((uint256,uint256,uint256,uint256,uint8,uint256,bool))' \
    "($position_id,0,0,$close_limit_price,2,$deadline,false)"
  position="$(cast call "$CONTROLLER" \
    'getPosition(uint256)((address,bytes32,address,address,uint256,uint128,uint128,uint128,uint64,uint40,uint40,uint8,uint8))' \
    "$position_id" --rpc-url "$RPC_URL" --json)"
  if (( $(jq -r '.[0][5]' <<<"$position") != 0 || $(jq -r '.[0][6]' <<<"$position") != 0 \
    || $(jq -r '.[0][12]' <<<"$position") != 5 )); then
    echo "$prefix position did not finish debt-free and closed." >&2
    exit 1
  fi
  echo "Completed $prefix $outcome position $position_id."

  printf -v "${prefix}_outcome" '%s' "$outcome"
  printf -v "${prefix}_generation_key" '%s' "$generation_key"
  printf -v "${prefix}_position_id" '%s' "$position_id"
  printf -v "${prefix}_shares_bought" '%s' "$shares_bought"
  printf -v "${prefix}_opening_debt" '%s' "$opening_debt"
  printf -v "${prefix}_open_tx" '%s' "$open_tx"
  printf -v "${prefix}_repay_tx" '%s' "$repay_tx"
  printf -v "${prefix}_close_tx" '%s' "$close_tx"
}

exercise_market btc
exercise_market eth
send_call controller_clear_tx "$COLLATERAL" 'approve(address,uint256)' "$CONTROLLER" 0

debt_shares="$(number_call "$VAULT" 'totalDebtShares()(uint256)')"
if (( debt_shares != 0 )); then
  echo "Vault still has $debt_shares debt shares after both closes." >&2
  exit 1
fi
balance_before="$(number_call "$COLLATERAL" 'balanceOf(address)(uint256)' "$ACCOUNT")"
send_call redeem_tx "$VAULT" 'redeem(uint256,address,address)' \
  "$smoke_vault_shares" "$ACCOUNT" "$ACCOUNT"
balance_after="$(number_call "$COLLATERAL" 'balanceOf(address)(uint256)' "$ACCOUNT")"
redeemed_assets="$((balance_after - balance_before))"
if (( redeemed_assets < VAULT_DEPOSIT )); then
  echo "Vault exit returned less than the original deposit." >&2
  exit 1
fi

jq -n \
  --arg schema "dreammargin.shannon-smoke.v1" \
  --argjson chainId 50312 \
  --argjson completedAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
  --arg account "$ACCOUNT" --arg controller "$CONTROLLER" --arg vault "$VAULT" \
  --arg faucetTransaction "$faucet_tx" --arg depositTransaction "$deposit_tx" \
  --arg btcOutcome "$btc_outcome" --arg btcGenerationKey "$btc_generation_key" \
  --argjson btcPositionId "$btc_position_id" --argjson btcSharesBought "$btc_shares_bought" \
  --argjson btcOpeningDebtAssets "$btc_opening_debt" --arg btcOpenTransaction "$btc_open_tx" \
  --arg btcRepayTransaction "$btc_repay_tx" --arg btcCloseTransaction "$btc_close_tx" \
  --arg ethOutcome "$eth_outcome" --arg ethGenerationKey "$eth_generation_key" \
  --argjson ethPositionId "$eth_position_id" --argjson ethSharesBought "$eth_shares_bought" \
  --argjson ethOpeningDebtAssets "$eth_opening_debt" --arg ethOpenTransaction "$eth_open_tx" \
  --arg ethRepayTransaction "$eth_repay_tx" --arg ethCloseTransaction "$eth_close_tx" \
  --argjson vaultSharesRedeemed "$smoke_vault_shares" --argjson vaultAssetsRedeemed "$redeemed_assets" \
  --arg redeemTransaction "$redeem_tx" \
  '{schema:$schema,chainId:$chainId,completedAtBlock:$completedAtBlock,account:$account,controller:$controller,vault:$vault,faucetTransaction:$faucetTransaction,depositTransaction:$depositTransaction,btcOutcome:$btcOutcome,btcGenerationKey:$btcGenerationKey,btcPositionId:$btcPositionId,btcSharesBought:$btcSharesBought,btcOpeningDebtAssets:$btcOpeningDebtAssets,btcOpenTransaction:$btcOpenTransaction,btcRepayTransaction:$btcRepayTransaction,btcCloseTransaction:$btcCloseTransaction,ethOutcome:$ethOutcome,ethGenerationKey:$ethGenerationKey,ethPositionId:$ethPositionId,ethSharesBought:$ethSharesBought,ethOpeningDebtAssets:$ethOpeningDebtAssets,ethOpenTransaction:$ethOpenTransaction,ethRepayTransaction:$ethRepayTransaction,ethCloseTransaction:$ethCloseTransaction,vaultSharesRedeemed:$vaultSharesRedeemed,vaultAssetsRedeemed:$vaultAssetsRedeemed,redeemTransaction:$redeemTransaction,finalVaultDebtShares:0}' \
  >"$OUTPUT"

echo "Lifecycle smoke test passed and wrote $OUTPUT"
