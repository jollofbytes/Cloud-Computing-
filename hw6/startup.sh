#!/bin/bash
# HW6 VM startup script. run_hw6.sh attaches it to the hw6-models VM with
#   --metadata-from-file startup-script=startup.sh,...
# The Python code travels in the VM metadata too, so nothing is copied by hand.
#
# It installs Python packages, runs migrate.py (3NF schema + data copy) and
# models.py (the 2 models), then uploads its log and a STATUS file (OK / FAILED)
# to the bucket. run_hw6.sh waits for that STATUS file.
# Runs as root, so no sudo.

MD=http://metadata.google.internal/computeMetadata/v1
attr() { curl -sf -H "Metadata-Flavor: Google" "$MD/instance/attributes/$1"; }

BUCKET=$(attr bucket-name)
OUT_PREFIX=$(attr out-prefix)
APP_DIR=/opt/hw6
LOG=/var/log/hw6.log

finish() {   # finish OK|FAILED : upload the log and the status, so run_hw6.sh can stop waiting
  echo "HW6 finished: $1" | tee -a "$LOG"
  gcloud storage cp "$LOG" "gs://$BUCKET/$OUT_PREFIX/vm_log.txt" --quiet
  echo "$1" | gcloud storage cp - "gs://$BUCKET/$OUT_PREFIX/STATUS" --quiet
  exit 0
}

if [ -f /var/log/hw6_already_ran ]; then
  echo "HW6 startup script already ran once. Skipping."
  exit 0
fi
touch /var/log/hw6_already_ran

{
  set -e
  echo "HW6 VM: installing packages"
  apt-get -o DPkg::Lock::Timeout=300 update -y
  apt-get -o DPkg::Lock::Timeout=300 install -y python3-venv

  mkdir -p "$APP_DIR"
  for f in db.py migrate.py models.py schema_3nf.sql migrate.sql requirements-vm.txt; do
    attr "file-${f//[._]/-}" > "$APP_DIR/$f"   # metadata keys: file-db-py, file-migrate-sql, ...
  done
  python3 -m venv "$APP_DIR/venv"
  "$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements-vm.txt"

  # Settings for db.py / models.py. The VM's service account is used for Cloud SQL
  # (role Cloud SQL Client) and for writing to the bucket.
  export PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "$MD/project/project-id")
  export REGION=$(attr region) DB_INSTANCE=$(attr db-instance)
  export DB_USER=$(attr db-user) DB_PASS=$(attr db-pass)
  export BUCKET_NAME="$BUCKET" OUT_PREFIX="$OUT_PREFIX" SEED=$(attr seed)
  export PYTHONUNBUFFERED=1

  cd "$APP_DIR"
  echo; echo "HW6 VM: step 1 - migrate to the 3NF schema"
  venv/bin/python migrate.py
  echo; echo "HW6 VM: step 2 - train and test the 2 models"
  venv/bin/python models.py
} 2>&1 | tee -a "$LOG"

# PIPESTATUS[0] is the exit code of the { ... } block, not of tee
if [ "${PIPESTATUS[0]}" -eq 0 ]; then finish OK; else finish FAILED; fi
