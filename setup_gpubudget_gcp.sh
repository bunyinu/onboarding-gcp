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

# Use simple, consistent service account name (one per mode per project)
SAFE_ID="gpubudget-${MODE}"
SA_EMAIL="${SAFE_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Function to delete a service account and its bindings
delete_service_account() {
  local sa_email="$1"
  local project="$2"

  echo "[gpubudget] Cleaning up service account: ${sa_email}"

  # Delete all user-managed keys
  gcloud iam service-accounts keys list --iam-account="$sa_email" \
    --project="$project" --format="value(name)" 2>/dev/null | \
  while read -r KEY_NAME; do
    if [[ -n "$KEY_NAME" ]] && [[ "$KEY_NAME" != *"/keys/system-"* ]]; then
      echo "[gpubudget]   Deleting key: ${KEY_NAME##*/}"
      gcloud iam service-accounts keys delete "$KEY_NAME" --iam-account="$sa_email" \
        --project="$project" --quiet 2>/dev/null || true
    fi
  done

  # Remove all possible IAM bindings
  for role in "roles/compute.viewer" "roles/compute.networkViewer" "roles/compute.admin" "roles/storage.admin" "roles/cloudbilling.viewer"; do
    gcloud projects remove-iam-policy-binding "$project" \
      --member="serviceAccount:${sa_email}" \
      --role="$role" --quiet 2>/dev/null || true
  done

  # Delete the service account
  gcloud iam service-accounts delete "$sa_email" \
    --project="$project" --quiet 2>/dev/null || true
}

# Clean up ALL existing gpubudget/tensorguard service accounts for this mode
echo "[gpubudget] Cleaning up existing service accounts..."
EXISTING_SAS=$(gcloud iam service-accounts list --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null | \
  grep -E "(gpubgt-${MODE}|gpubudget-${MODE}|tensorguard-${MODE})" || true)

if [ -n "$EXISTING_SAS" ]; then
  echo "[gpubudget] Found existing service accounts to clean up:"
  echo "$EXISTING_SAS" | while read -r existing_sa; do
    if [ -n "$existing_sa" ]; then
      delete_service_account "$existing_sa" "$PROJECT_ID"
    fi
  done
  # Wait for deletion to propagate
  echo "[gpubudget] Waiting for cleanup to propagate..."
  sleep 5
else
  echo "[gpubudget] No existing service accounts found."
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

KEY_FILE="gpubudget-${MODE}-${PROJECT_ID}-key.json"
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
