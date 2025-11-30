#!/usr/bin/env bash
# usage: ./setup_gpubudget_gcp.sh <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff> [PROJECT_ID]

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff> [PROJECT_ID]"
  exit 1
fi

EXTERNAL_ID="$1"
CALLBACK_TOKEN="$2"
MODE="$3"
PROJECT_ARG="${4:-}"

CALLBACK_URL="https://api.gpubudget.com/api/v1/onboarding/gcp/callback"

# Resolve project: prefer CLI arg, then current config, else interactive pick
PROJECT_ID="$PROJECT_ARG"
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [ -z "$PROJECT_ID" ]; then
  echo "[gpubudget] No GCP project set. Listing projects..."
  mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" --limit=50)
  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    echo "[gpubudget] No projects available. Set one with: gcloud config set project YOUR_PROJECT_ID"
    exit 1
  fi
  echo "[gpubudget] Select a project:"
  select P in "${PROJECTS[@]}"; do
    if [ -n "$P" ]; then
      PROJECT_ID="$P"
      break
    fi
    echo "Invalid choice, try again."
  done
fi

echo "[gpubudget] Using project ${PROJECT_ID}"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

SA_NAME="gpubudget-${MODE}-${EXTERNAL_ID}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "[gpubudget] Creating service account ${SA_EMAIL}..."
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
else
  echo "[gpubudget] Granting admin roles..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.admin" \
    --quiet
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.admin" \
    --quiet
fi

KEY_FILE="gpubudget-${MODE}-${EXTERNAL_ID}-key.json"
echo "[gpubudget] Creating key ${KEY_FILE}..."
gcloud iam service-accounts keys create "${KEY_FILE}" \
  --iam-account="${SA_EMAIL}" \
  --project="$PROJECT_ID"

SA_KEY_B64=$(base64 -w0 "${KEY_FILE}" 2>/dev/null || base64 "${KEY_FILE}")

PAYLOAD=$(cat <<EOF_PAYLOAD
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
EOF_PAYLOAD
)

echo "[gpubudget] Sending onboarding callback..."
curl -sS -X POST "$CALLBACK_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CALLBACK_TOKEN" \
  -d "$PAYLOAD"

echo "[gpubudget] Done."
