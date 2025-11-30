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

# If no project ID was provided in arguments, we MUST ask the user (if interactive)
if [ -z "$PROJECT_ID" ]; then
  
  # 1. Check for interactive shell
  if [ -t 0 ]; then
    echo "[gpubudget] No project ID provided. Fetching your projects..."
    
    # Get current default just for reference
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
    
    # Interactive Menu
    PS3="Enter the number of your choice: "
    select P in "${PROJECTS[@]}"; do
      if [ -n "$P" ]; then
        PROJECT_ID="$P"
        break
      fi
      echo "Invalid selection. Please try again."
    done

  else
    # 2. Non-interactive mode (CI/CD) fallback
    # Only here do we auto-select the current config to prevent hanging
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    if [ -z "$PROJECT_ID" ]; then
       # If still empty, try to grab the first one from the list
       PROJECT_ID=$(gcloud projects list --format="value(projectId)" --limit=1)
    fi
    
    if [ -z "$PROJECT_ID" ]; then
        echo "[gpubudget] Error: No project provided and none could be detected."
        exit 1
    fi
    echo "[gpubudget] Non-interactive mode detected. Using project: $PROJECT_ID"
  fi
fi

echo "[gpubudget] Onboarding Project: ${PROJECT_ID}"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || true


# --- ID GENERATION & ACCOUNT CREATION (Fixed) ---

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

echo "[gpubudget] Creating service account ${SA_EMAIL}..."

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "[gpubudget] Service account already exists. Skipping creation."
else
    gcloud iam service-accounts create "$SAFE_ID" \
      --display-name="gpubudget ${MODE}" \
      --project="$PROJECT_ID"
fi

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
