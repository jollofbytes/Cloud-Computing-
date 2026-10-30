#!/bin/bash
# Shared settings for every HW5 script (sourced, not run directly).
# The project ID is hardcoded on purpose (assignment requirement) - never looked up.

PROJECT_ID="solar-attic-508721-n0"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"   # every gcloud call in these scripts uses this project

REGION="us-central1"
ZONE="us-central1-a"

# Cloud Storage + Pub/Sub (from HW2-HW4)
BUCKET="cs528hww2"
WEB_DIR="CS528-HW_2-output-x2Yenv"
TOPIC="forbidden-requests"
SUBSCRIPTION="forbidden-requests-sub"

# Cloud SQL
DB_INSTANCE="hw5-db"
DB_TIER="db-n1-standard-1"     # 1 dedicated vCPU, 3.75 GB (what hw5-db was created with)
DB_NAME="hw5"
DB_USER="hw5-user"
DB_PASS="${DB_PASS:-CHANGE-ME}"  # real password is NOT in the repo: run  DB_PASS='...' bash setup.sh  (see README)
DB_CONNECTION="$PROJECT_ID:$REGION:$DB_INSTANCE"

# VMs
SERVER_VM="hw5-server"
FORBIDDEN_VM="hw5-forbidden"
CLIENT_VM="hw5-client"
SERVER_MACHINE="e2-medium"       # 2 vCPUs: handles 2 concurrent clients comfortably
IP_NAME="hw5-server-ip"
FIREWALL_RULE="hw5-allow-http"
NETWORK_TAG="hw5-server"

# Service accounts (least privilege, one per job)
SERVER_SA="hw5-server-sa@$PROJECT_ID.iam.gserviceaccount.com"
FORBIDDEN_SA="hw5-forbidden-sa@$PROJECT_ID.iam.gserviceaccount.com"
WATCHDOG_SA="hw5-watchdog-sa@$PROJECT_ID.iam.gserviceaccount.com"

# Database watchdog (Cloud Function, called hourly by Cloud Scheduler)
FUNCTION="hw5-db-watchdog"
SCHEDULER_JOB="hw5-db-watchdog-hourly"

# Python virtual env for the scripts that run on your computer (setup_schema.py etc.)
VENV=".venv"

# ---- helpers ----
exists() { "$@" >/dev/null 2>&1; }   # true if a describe/list command succeeds
step()   { echo; echo "== $* =="; }
server_ip() { gcloud compute addresses describe "$IP_NAME" --region="$REGION" --format='value(address)'; }

ensure_venv() {
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q -r requirements.txt
  fi
}
