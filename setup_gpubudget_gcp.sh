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
# 4th arg is optional Project ID
PROJECT_ARG="${4:-${GPUBUDGET_PROJECT:-}}"

# --- PROJECT SELECTION LOGIC ---
PROJECT_ID="$PROJECT_ARG"

# If no project ID provided, FORCE interactive menu even if piped via curl
if [ -z "$PROJECT_ID" ]; then
    
    echo "[gpubudget] No project ID provided. Fetching your projects..."
    
    # Check if we have a valid terminal to read from
    if [ ! -c /dev/tty ]; then
        echo "Error: Cannot show menu. Please provide PROJECT_ID as the 4th argument."
        exit 1
    fi

    # Get current default for reference
    CURRENT_DEFAULT=$(gcloud config get-value project 2>/dev/null || true)
    
    # List available projects
    mapfile -t PROJECTS < <(gcloud projects list --format="value(projectId)" --limit=50)
    
    if [ "${#PROJECTS[@]}" -eq 0 ]; then
      echo "No projects found. Please create one or login with 'gcloud auth login'."
      exit 1
    fi

    echo "--------------------------------------------------------"
    echo "Please select the project to onboard:"
    if [ -n "$CURRENT_DEFAULT" ]; then
        echo "(Your current active config is: $CURRENT_DEFAULT)"
    fi
    
    # We redirect input from /dev/tty so the menu works even inside 'curl | bash'
    PS3="Enter the number of your choice: "
    select P in "${PROJECTS[@]}"; do
      if [ -n "$P" ]; then
        PROJECT_ID="$P"
        break
      fi
      echo "Invalid selection. Please try again."
    done < /dev/tty
fi

echo "[gpubudget] Onboarding Project: ${PROJECT_ID}"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true


# --- ID GENERATION & ACCOUNT MANAGEMENT ---

BASE_ID="gpubgt-${MODE}-${EXTERNAL_ID}"
SAFE_ID=$(echo "$BASE_ID" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

# Truncate to 30 chars max with hash suffix if needed
if [ "${#SAFE_ID}" -gt 30 ]; then
  if command -v sha1sum >/dev/null 2>&1; then
      HASH_SUFFIX=$(echo -n "$EXTERNAL_ID" | sha1sum | cut -c1-6)
  else
      HASH_SUFFIX=$(echo -n "$EXTERNAL_ID" | cksum | cut -d' ' -f1 | cut -c1-6)
  fi
  SAFE_ID="$(echo "$SAFE_ID" | cut -c1-23)-${HASH_SUFFIX}"
fi

SA_EMAIL="${SAFE_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "[gpubudget] Checking for existing service account ${SA_EMAIL}..."

# DELETE existing account if found (Fresh Start)
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "[gpubudget] Found existing account. Deleting it to ensure a fresh setup..."
    gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT_ID" --quiet
    echo "[gpubudget] Deleted."
fi

# Create new account
echo "[gpubudget] Creating service account..."
gcloud iam service-accounts create "$SAFE_ID" \
  --display-name="gpubudget ${MODE}" \
  --project="$PROJECT_ID"

# Grant Roles
if [ "$MODE" = "auditor" ]; then
  echo "[gpubudget] Granting viewer roles..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.viewer" \
    --quiet >/dev/null
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/compute.networkViewer" \
    --quiet >/dev/null
fi

echo "[gpubudget] Setup complete for project ${PROJECT_ID}."
