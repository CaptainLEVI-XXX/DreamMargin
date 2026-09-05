#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export CONFIGURATION="$CONTRACTS_DIR/deployments/shannon-demo-markets.json"
export OBSERVATION_OUTPUT="$CONTRACTS_DIR/deployments/shannon-demo-oracle-observation.json"

"$SCRIPT_DIR/observe-shannon.sh"
sleep 35
sleep 35
"$SCRIPT_DIR/observe-shannon.sh"

echo "All four demo generations have a mature initial TWAP window."
