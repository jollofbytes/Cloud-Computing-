#!/bin/bash
# Shared settings for the HW6 scripts (sourced, not run directly).
# Reuses the HW5 project, bucket and Cloud SQL instance.

PROJECT_ID="solar-attic-508721-n0"          # hardcoded on purpose (same as HW5)
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"  # every gcloud call below uses this project

REGION="us-central1"
ZONE="us-central1-a"

# Cloud Storage: the bucket from the earlier homeworks. Model outputs go to gs://$BUCKET/$OUT_PREFIX/
BUCKET="cs528hww2"
OUT_PREFIX="hw6"

# Cloud SQL (created in HW5). The 3NF tables go in a new database, hw6, on the same instance.
DB_INSTANCE="hw5-db"
DB_USER="hw5-user"
DB_PASS="${DB_PASS:-CHANGE-ME}"   # real password is NOT in the repo: DB_PASS='...' bash run_hw6.sh

# The VM that runs the models (deleted at the end of every run)
VM_NAME="hw6-models"
VM_MACHINE="e2-medium"            # 2 vCPUs, 4 GB: enough for scikit-learn on 100k rows
VM_SA_NAME="hw6-models-sa"
VM_SA="$VM_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# HW5's hourly watchdog that stops the database (paused while we use it)
SCHEDULER_JOB="hw5-db-watchdog-hourly"

# ---- helpers ----
exists() { "$@" >/dev/null 2>&1; }   # true if a describe/list command succeeds
step()   { echo; echo "== $* =="; }
