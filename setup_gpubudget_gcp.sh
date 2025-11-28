#!/usr/bin/env bash
# usage: ./setup_gpubudget_gcp.sh <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff>

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff>"
  exit 1
fi

EXTERNAL_ID="$1"
CALLBACK_TOKEN="$2"
MODE="$3"

CALLBACK_URL="https://api.gpubudget.com/api/v1/onboarding/gcp/callback"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ]; then
  echo "[gpubudget] No GCP project set. Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

SA_NAME="gpubudget-${MODE}-${EXTERNAL_ID}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "[gpubudget] Creating service account ${SA_EMAIL} (if not exists)..."
gcloud iam service-accounts create "$SA_NAME" \
  --display-name="gpubudget ${MODE} (${EXTERNAL_ID})" \
  --project="$PROJECT_ID" || true

if [ "$MODE" = "auditor" ]; then
  echo "[gpubudget] Granting viewer roles..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.viewer" \
    --quiet
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.networkViewer" \
    --quiet
elif [ "$MODE" = "sheriff" ]; then
  echo "[gpubudget] Granting admin roles..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.admin" \
    --quiet
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.admin" \
    --quiet
else
  echo "Unknown MODE: $MODE (expected auditor|sheriff)"
  exit 1
fi

KEY_FILE="gpubudget-${MODE}-${EXTERNAL_ID}-key.json"
echo "[gpubudget] Creating key ${KEY_FILE}..."
gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account="${SA_EMAIL}" \
  --project="$PROJECT_ID"

if command -v base64 >/dev/null 2>&1; then
  SA_KEY_B64=$(base64 -w0 "${KEY_FILE}" 2>/dev/null || base64 "${KEY_FILE}")
else
  echo "[gpubudget] base64 not found in PATH."
  exit 1
fi

echo "[gpubudget] Sending onboarding callback..."
JSON=$(cat <<EOF
{
  "provider": "gcp",
  "mode": "$MODE",
  "external_id": "$EXTERNAL_ID",
  "account_id": "$PROJECT_ID",
  "meta": {
    "sa_email": "${SA_EMAIL}",
    "sa_key_b64": "${SA_KEY_B64}"
  }
}
EOF
)

curl -sS -X POST "$CALLBACK_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CALLBACK_TOKEN" \
  -d "$JSON"

echo "[gpubudget] Done."

