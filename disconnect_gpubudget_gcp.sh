#!/usr/bin/env bash
# Disconnect GPUBudget from GCP
# Usage: ./disconnect_gpubudget_gcp.sh <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff>

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff>"
  exit 1
fi

EXTERNAL_ID="$1"
CALLBACK_TOKEN="$2"
MODE="$3"

CALLBACK_URL="https://api.gpubudget.com/api/v1/onboarding/gcp/callback"

if [ "$MODE" != "auditor" ] && [ "$MODE" != "sheriff" ]; then
  echo "[gpubudget] Invalid mode: $MODE (must be auditor or sheriff)"
  exit 1
fi

echo "[gpubudget] Sending disconnect callback for GCP ${MODE}..."

PAYLOAD=$(cat <<EOF
{
  "provider": "gcp",
  "mode": "$MODE",
  "external_id": "$EXTERNAL_ID",
  "account_id": "",
  "action": "disconnect",
  "meta": {}
}
EOF
)

RESPONSE=$(curl -sS -X POST "$CALLBACK_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CALLBACK_TOKEN" \
  -d "$PAYLOAD")

echo "[gpubudget] Response: $RESPONSE"
echo "[gpubudget] GCP ${MODE} disconnected."
