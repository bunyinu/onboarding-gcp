#!/usr/bin/env bash
# usage: ./setup_gpubudget_gcp.sh <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff> [connect|disconnect] [PROJECT_ID]

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
  echo "Usage: $0 <EXTERNAL_ID> <CALLBACK_TOKEN> <auditor|sheriff> [connect|disconnect] [PROJECT_ID]"
  exit 1
fi

EXTERNAL_ID="$1"
CALLBACK_TOKEN="$2"
MODE="$3"
ACTION="${4:-connect}"
PROJECT_ARG="${5:-${GPUBUDGET_PROJECT:-}}"

CALLBACK_URL="https://api.gpubudget.com/api/v1/onboarding/gcp/callback"

if [ "$MODE" != "auditor" ] && [ "$MODE" != "sheriff" ]; then
  echo "[gpubudget] Invalid mode: $MODE (must be auditor or sheriff)"
  exit 1
fi

# Handle disconnect action
if [ "$ACTION" = "disconnect" ]; then
  echo "[gpubudget] Disconnecting GCP ${MODE}..."

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
  exit 0
fi

# Connect action (default)
# Resolve project: prefer CLI arg, else always prompt user to select
PROJECT_ID="$PROJECT_ARG"
if [ -z "$PROJECT_ID" ]; then
  echo "[gpubudget] Fetching available GCP projects..."
  mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" --limit=50)
  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    echo "[gpubudget] No projects available. Create a project first or check your permissions."
    exit 1
  fi

  CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  DEFAULT_PROJECT="${CURRENT_PROJECT:-${PROJECTS[0]}}"

  if [ -t 0 ]; then
    echo ""
    echo "[gpubudget] Available projects:"
    for i in "${!PROJECTS[@]}"; do
      if [ "${PROJECTS[$i]}" = "$DEFAULT_PROJECT" ]; then
        echo "  $((i+1))) ${PROJECTS[$i]} (current)"
      else
        echo "  $((i+1))) ${PROJECTS[$i]}"
      fi
    done
    echo ""
    read -rp "[gpubudget] Enter project number or name [default: ${DEFAULT_PROJECT}]: " PROJECT_INPUT
    if [ -z "$PROJECT_INPUT" ]; then
      PROJECT_ID="$DEFAULT_PROJECT"
    elif [[ "$PROJECT_INPUT" =~ ^[0-9]+$ ]] && [ "$PROJECT_INPUT" -ge 1 ] && [ "$PROJECT_INPUT" -le "${#PROJECTS[@]}" ]; then
      PROJECT_ID="${PROJECTS[$((PROJECT_INPUT-1))]}"
    else
      # Assume it's a project name
      PROJECT_ID="$PROJECT_INPUT"
    fi
  else
    echo "[gpubudget] Non-interactive shell detected; using ${DEFAULT_PROJECT}"
    PROJECT_ID="$DEFAULT_PROJECT"
  fi
fi

echo "[gpubudget] Using project ${PROJECT_ID}"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true

# Build a safe service account ID: lowercase, alnum, <=30 chars.
BASE_ID="gpubgt-${MODE}-${EXTERNAL_ID}"
SAFE_ID=$(echo "$BASE_ID" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
HASH_SUFFIX=$(echo -n "$EXTERNAL_ID" | sha1sum | cut -c1-6)
if [ "${#SAFE_ID}" -gt 30 ]; then
  SAFE_ID="$(echo "$SAFE_ID" | cut -c1-$((30-${#HASH_SUFFIX}-1)))-${HASH_SUFFIX}"
fi
SA_EMAIL="${SAFE_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Check if service account already exists and delete it
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "[gpubudget] Found existing service account ${SA_EMAIL}, deleting..."

  # Delete all keys first
  echo "[gpubudget] Deleting existing keys..."
  gcloud iam service-accounts keys list --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" --format="value(name)" 2>/dev/null | \
  while read -r KEY_NAME; do
    # Skip the system-managed key
    if [[ "$KEY_NAME" != *"/keys/system-"* ]]; then
      gcloud iam service-accounts keys delete "$KEY_NAME" --iam-account="$SA_EMAIL" \
        --project="$PROJECT_ID" --quiet 2>/dev/null || true
    fi
  done

  # Remove IAM policy bindings
  echo "[gpubudget] Removing IAM policy bindings..."
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.viewer" --quiet 2>/dev/null || true
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.networkViewer" --quiet 2>/dev/null || true
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.admin" --quiet 2>/dev/null || true
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.admin" --quiet 2>/dev/null || true

  # Delete the service account
  echo "[gpubudget] Deleting service account..."
  gcloud iam service-accounts delete "$SA_EMAIL" \
    --project="$PROJECT_ID" --quiet || true

  # Wait for propagation
  sleep 3
fi

echo "[gpubudget] Creating service account ${SA_EMAIL}..."
gcloud iam service-accounts create "$SAFE_ID" \
  --display-name="gpubudget ${MODE} (${EXTERNAL_ID})" \
  --project="$PROJECT_ID"

# Wait for service account to propagate before adding IAM bindings
echo "[gpubudget] Waiting for service account to propagate..."
sleep 5

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
  "action": "connect",
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
