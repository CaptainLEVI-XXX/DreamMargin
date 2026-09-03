#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$CONTRACTS_DIR/.env}"
DEPLOYMENT="$CONTRACTS_DIR/deployments/shannon-deployment.json"
CONFIGURATION="$CONTRACTS_DIR/deployments/shannon-market-configuration.json"
OUTPUT="$CONTRACTS_DIR/deployments/shannon-oracle-observation.json"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RPC_URL="${RPC_URL:-$SOMNIA_RPC_URL}"
oracle="$(jq -r '.oracle' "$DEPLOYMENT")"
keys=(
  "$(jq -r '.btcYesGenerationKey' "$CONFIGURATION")"
  "$(jq -r '.btcNoGenerationKey' "$CONFIGURATION")"
  "$(jq -r '.ethYesGenerationKey' "$CONFIGURATION")"
  "$(jq -r '.ethNoGenerationKey' "$CONFIGURATION")"
)
hashes=()

for key in "${keys[@]}"; do
  receipt="$(cast send "$oracle" 'observe(bytes32)' "$key" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --json)"
  if [[ "$(jq -r '.status' <<<"$receipt")" != "0x1" ]]; then
    echo "Oracle observation failed for $key." >&2
    exit 1
  fi
  transaction_hash="$(jq -r '.transactionHash' <<<"$receipt")"
  hashes+=("$transaction_hash")
  echo "Observed $key ($transaction_hash)."
done

round=1
if [[ -f "$OUTPUT" ]]; then
  round="$(( $(jq -r '.round // 0' "$OUTPUT") + 1 ))"
fi

jq -n \
  --arg schema "dreammargin.shannon-observations.v1" \
  --argjson chainId 50312 \
  --argjson round "$round" \
  --argjson observedAtBlock "$(cast block-number --rpc-url "$RPC_URL")" \
  --argjson observedAtTimestamp "$(date +%s)" \
  --arg oracle "$oracle" \
  --arg btcYesGenerationKey "${keys[0]}" \
  --arg btcNoGenerationKey "${keys[1]}" \
  --arg ethYesGenerationKey "${keys[2]}" \
  --arg ethNoGenerationKey "${keys[3]}" \
  --arg btcYesTransaction "${hashes[0]}" \
  --arg btcNoTransaction "${hashes[1]}" \
  --arg ethYesTransaction "${hashes[2]}" \
  --arg ethNoTransaction "${hashes[3]}" \
  '{schema:$schema,chainId:$chainId,round:$round,observedAtBlock:$observedAtBlock,observedAtTimestamp:$observedAtTimestamp,oracle:$oracle,btcYesGenerationKey:$btcYesGenerationKey,btcNoGenerationKey:$btcNoGenerationKey,ethYesGenerationKey:$ethYesGenerationKey,ethNoGenerationKey:$ethNoGenerationKey,btcYesTransaction:$btcYesTransaction,btcNoTransaction:$btcNoTransaction,ethYesTransaction:$ethYesTransaction,ethNoTransaction:$ethNoTransaction}' \
  >"$OUTPUT"

echo "Wrote observation round $round to $OUTPUT"
