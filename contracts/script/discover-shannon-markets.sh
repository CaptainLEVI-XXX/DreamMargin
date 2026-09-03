#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-selected-markets.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE; copy .env.example and configure it." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${SHANNON_INDEXER_URL:?set SHANNON_INDEXER_URL}"
: "${DREAMDEX_VENUE_ID:?set DREAMDEX_VENUE_ID}"

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "Missing required command: $tool" >&2; exit 1; }
done

headroom="${MARKET_EXPIRY_HEADROOM_SECONDS:-21600}"
if [[ ! "$headroom" =~ ^[0-9]+$ ]]; then
  echo "MARKET_EXPIRY_HEADROOM_SECONDS must be an integer." >&2
  exit 1
fi

now="$(date +%s)"
minimum_expiry="$((now + headroom))"
venue_id="$(printf '%s' "$DREAMDEX_VENUE_ID" | tr '[:upper:]' '[:lower:]')"

query='query LiveDaily($where: Market_bool_exp!) {
  Market(where: $where, order_by: {expiry: asc}, limit: 50) {
    marketId marketAddress poolAddress nonce yesTokenId noTokenId collateral asset
    tradingStart expiry clobStatus venueId operatorId intervalSec question
  }
}'
variables="$(jq -cn \
  --arg venue "$venue_id" \
  --arg expiry "$minimum_expiry" \
  '{where:{marketType:{_eq:"BINARY"},venueId:{_eq:$venue},intervalSec:{_eq:"86400"},clobStatus:{_eq:"Trading"},expiry:{_gt:$expiry},asset:{_in:["BTC","ETH"]}}}')"
payload="$(jq -cn --arg query "$query" --argjson variables "$variables" '{query:$query,variables:$variables}')"

response="$(curl --fail --silent --show-error \
  --connect-timeout 15 --max-time 45 \
  --header 'content-type: application/json' \
  --data "$payload" \
  "$SHANNON_INDEXER_URL")"

if [[ "$(jq '.errors | length // 0' <<<"$response")" != "0" ]]; then
  jq '.errors' <<<"$response" >&2
  exit 1
fi

btc="$(jq -c '.data.Market | map(select(.asset == "BTC")) | first // empty' <<<"$response")"
eth="$(jq -c '.data.Market | map(select(.asset == "ETH")) | first // empty' <<<"$response")"
if [[ -z "$btc" || -z "$eth" ]]; then
  echo "No live BTC and ETH daily markets satisfy the configured expiry headroom." >&2
  exit 1
fi

for row in "$btc" "$eth"; do
  market_id="$(jq -r '.marketId' <<<"$row")"
  pool="$(jq -r '.poolAddress' <<<"$row")"
  if [[ ! "$market_id" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "Indexer returned a malformed market ID." >&2
    exit 1
  fi
  if [[ ! "$pool" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Indexer returned a malformed pool address." >&2
    exit 1
  fi
done

jq -n \
  --arg schema "dreammargin.shannon-selection.v1" \
  --argjson discoveredAt "$now" \
  --arg venueId "$venue_id" \
  --argjson requiredHeadroomSeconds "$headroom" \
  --argjson btc "$btc" \
  --argjson eth "$eth" \
  '{schema:$schema,discoveredAt:$discoveredAt,venueId:$venueId,requiredHeadroomSeconds:$requiredHeadroomSeconds,btc:$btc,eth:$eth}' \
  >"$OUTPUT"

echo "Pinned BTC $(jq -r '.marketId' <<<"$btc") expiring $(jq -r '.expiry' <<<"$btc")"
echo "Pinned ETH $(jq -r '.marketId' <<<"$eth") expiring $(jq -r '.expiry' <<<"$eth")"
echo "Wrote $OUTPUT"
