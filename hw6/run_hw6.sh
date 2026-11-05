#!/bin/bash
# CS528 HW6 - one script does the whole run:
#   1. starts the Cloud SQL database (hw5-db) and waits until it is ready
#   2. creates a service account for the VM (only the permissions it needs)
#   3. creates the hw6-models VM; its startup script runs migrate.py + models.py
#   4. waits for the VM to finish (it writes gs://BUCKET/hw6/STATUS)
#   5. stops the database and deletes the VM  (also done if the script fails or you press Ctrl+C)
#   6. prints the output files from the bucket on the terminal
#
#   DB_PASS='<hw5-user password>' bash run_hw6.sh
#   DB_PASS='...' FULL=1 bash run_hw6.sh    # print every line of the prediction files
#
# Needs: gcloud logged in (gcloud auth login) as a project Owner/Editor,
# and the HW5 Cloud SQL instance hw5-db with its hw5 database.

cd "$(dirname "$0")" || exit 1   # so the files next to this script are found
source ./config.sh
SEED="${SEED:-528}"

if [ "$DB_PASS" = "CHANGE-ME" ]; then
  echo "ERROR: set the database password first:  DB_PASS='<hw5-user password>' bash run_hw6.sh"
  exit 1
fi

# ------------------------------------------------------------------ clean-up (always runs)
CLEANED=0
PASS_FILE=""
cleanup() {
  [ "$CLEANED" = 1 ] && return
  CLEANED=1
  rm -f "$PASS_FILE"
  step "Stopping the database (not deleting it)"
  gcloud sql instances patch "$DB_INSTANCE" --activation-policy=NEVER --quiet >/dev/null 2>&1
  gcloud sql instances describe "$DB_INSTANCE" --format='value(name,state,settings.activationPolicy)'

  step "Deleting the VM"
  if exists gcloud compute instances describe "$VM_NAME" --zone="$ZONE"; then
    gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --quiet
  else
    echo "$VM_NAME not found (already deleted)"
  fi

  # Turn HW5's hourly "stop the database" watchdog back on.
  if exists gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION"; then
    gcloud scheduler jobs resume "$SCHEDULER_JOB" --location="$REGION" --quiet >/dev/null 2>&1
    echo "Hourly DB watchdog resumed"
  fi
}
trap cleanup EXIT                  # runs when the script ends, even after an error
trap 'cleanup; exit 1' INT TERM    # and when you press Ctrl+C

# ------------------------------------------------------------------ 1. database
step "Enabling the APIs"
gcloud services enable compute.googleapis.com sqladmin.googleapis.com storage.googleapis.com \
  iam.googleapis.com

step "Starting Cloud SQL ($DB_INSTANCE)"
if ! exists gcloud sql instances describe "$DB_INSTANCE"; then
  echo "ERROR: $DB_INSTANCE not found. Create it with hw5/setup.sh first."
  exit 1
fi
# The watchdog would stop the database while we use it, so pause it first.
exists gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION" && \
  gcloud scheduler jobs pause "$SCHEDULER_JOB" --location="$REGION" --quiet >/dev/null 2>&1
gcloud sql instances patch "$DB_INSTANCE" --activation-policy=ALWAYS --quiet >/dev/null
echo -n "Waiting for $DB_INSTANCE"
for _ in $(seq 1 90); do   # up to 15 minutes
  state=$(gcloud sql instances describe "$DB_INSTANCE" --format='value(state)')
  busy=$(gcloud sql operations list --instance="$DB_INSTANCE" --filter='status!=DONE' --format='value(name)')
  if [ "$state" = "RUNNABLE" ] && [ -z "$busy" ]; then echo " ready"; break; fi
  echo -n "."; sleep 10
done
[ "$state" = "RUNNABLE" ] || { echo; echo "ERROR: database did not start"; exit 1; }

# ------------------------------------------------------------------ 2. service account
step "Service account for the VM: $VM_SA_NAME"
if ! exists gcloud iam service-accounts describe "$VM_SA"; then
  gcloud iam service-accounts create "$VM_SA_NAME" --display-name="CS528 HW6 models VM"
  sleep 15   # a new account takes a moment before it can be given roles
fi
# Connect to Cloud SQL, and read/write objects in this one bucket only.
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$VM_SA" \
  --role=roles/cloudsql.client --condition=None >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$VM_SA" \
  --role=roles/storage.objectUser >/dev/null
echo "Roles: Cloud SQL Client (project), Storage Object User (bucket $BUCKET only)"

# ------------------------------------------------------------------ 3. VM
step "Removing old outputs in gs://$BUCKET/$OUT_PREFIX/"
gcloud storage rm "gs://$BUCKET/$OUT_PREFIX/**" --quiet 2>/dev/null || echo "(nothing to remove)"

step "Creating the VM $VM_NAME"
if exists gcloud compute instances describe "$VM_NAME" --zone="$ZONE"; then
  echo "An old $VM_NAME exists -> deleting it first"
  gcloud compute instances delete "$VM_NAME" --zone="$ZONE" --quiet
fi
# The password goes in through a private temp file, so any character in it is safe.
PASS_FILE=$(mktemp)
chmod 600 "$PASS_FILE"
printf '%s' "$DB_PASS" > "$PASS_FILE"
gcloud compute instances create "$VM_NAME" --zone="$ZONE" --machine-type="$VM_MACHINE" \
  --image-family=debian-12 --image-project=debian-cloud \
  --service-account="$VM_SA" --scopes=cloud-platform \
  --metadata="bucket-name=$BUCKET,out-prefix=$OUT_PREFIX,region=$REGION,db-instance=$DB_INSTANCE,db-user=$DB_USER,seed=$SEED" \
  --metadata-from-file="startup-script=startup.sh,db-pass=$PASS_FILE,file-db-py=db.py,file-migrate-py=migrate.py,file-models-py=models.py,file-schema-3nf-sql=schema_3nf.sql,file-migrate-sql=migrate.sql,file-requirements-vm-txt=requirements-vm.txt" \
  || exit 1
rm -f "$PASS_FILE"

# ------------------------------------------------------------------ 4. wait
step "Waiting for the VM to install packages, migrate the data and run the models (~5 min)"
STATUS=""
for i in $(seq 1 120); do   # up to 30 minutes
  STATUS=$(gcloud storage cat "gs://$BUCKET/$OUT_PREFIX/STATUS" 2>/dev/null)
  [ -n "$STATUS" ] && break
  [ $((i % 4)) = 0 ] && echo "  still running ($((i * 15 / 60)) min)..."
  sleep 15
done
echo "VM status: ${STATUS:-TIMED OUT}"

# ------------------------------------------------------------------ 5. clean-up
cleanup

# ------------------------------------------------------------------ 6. print the outputs
step "Files in gs://$BUCKET/$OUT_PREFIX/"
gcloud storage ls -l "gs://$BUCKET/$OUT_PREFIX/"

if [ "$STATUS" != "OK" ]; then
  step "The VM did not finish OK. Its log:"
  gcloud storage cat "gs://$BUCKET/$OUT_PREFIX/vm_log.txt" 2>/dev/null || \
    echo "(no log in the bucket - the VM may not have started; check the serial console)"
  exit 1
fi

step "gs://$BUCKET/$OUT_PREFIX/summary.txt"
gcloud storage cat "gs://$BUCKET/$OUT_PREFIX/summary.txt"

for f in model1_ip_to_country_test_predictions.csv model2_income_test_predictions.csv; do
  url="gs://$BUCKET/$OUT_PREFIX/$f"
  if [ "${FULL:-0}" = 1 ]; then
    step "$url (all rows)"
    gcloud storage cat "$url"
  else
    rows=$(($(gcloud storage cat "$url" | wc -l) - 1))
    step "$url (first 20 of $rows rows; FULL=1 prints all)"
    gcloud storage cat "$url" 2>/dev/null | head -n 21
  fi
done

echo; echo "Done. The database is stopped and the VM is deleted."
