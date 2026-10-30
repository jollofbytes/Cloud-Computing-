#!/bin/bash
# CS528 HW5 - creates (or restarts) everything HW5 needs:
#   APIs, Pub/Sub, service accounts + permissions, the hourly DB watchdog,
#   Cloud SQL (create + schema on first run, otherwise just start it),
#   static IP + firewall, and 3 VMs (web server, forbidden service, client).
#
#   bash setup.sh
#
# Safe to rerun: anything that already exists is skipped.
# Needs: gcloud logged in (`gcloud auth login`) as a project Owner/Editor, python3,
# and the bucket from HW2 holding the web files.

PROJECT_ID="solar-attic-508721-n0"   # hardcoded on purpose - see config.sh
cd "$(dirname "$0")" || exit 1        # so the files next to this script are found
source ./config.sh

if [ "$DB_PASS" = "CHANGE-ME" ]; then
  echo "WARNING: DB_PASS is not set. Run:  DB_PASS='<hw5-user password>' bash setup.sh  (see README)."
  echo "Continuing: the server will serve files, but its database inserts will be refused."
fi

# ------------------------------------------------------------------ APIs
enable_apis() {
  step "Enabling APIs"
  gcloud services enable compute.googleapis.com sqladmin.googleapis.com \
    pubsub.googleapis.com logging.googleapis.com storage.googleapis.com \
    cloudfunctions.googleapis.com cloudbuild.googleapis.com run.googleapis.com \
    artifactregistry.googleapis.com cloudscheduler.googleapis.com iam.googleapis.com
}

# ------------------------------------------------------------------ Pub/Sub
setup_pubsub() {
  step "Pub/Sub topic + subscription (Service 1 -> Service 2)"
  exists gcloud pubsub topics describe "$TOPIC" || gcloud pubsub topics create "$TOPIC"
  exists gcloud pubsub subscriptions describe "$SUBSCRIPTION" || \
    gcloud pubsub subscriptions create "$SUBSCRIPTION" --topic="$TOPIC"
}

# ------------------------------------------------------------------ IAM
setup_service_accounts() {
  step "Service accounts"
  for sa in "$SERVER_SA" "$FORBIDDEN_SA" "$WATCHDOG_SA"; do
    name=${sa%%@*}
    exists gcloud iam service-accounts describe "$sa" || {
      gcloud iam service-accounts create "$name" --display-name="CS528 $name"
      sleep 10   # new accounts take a moment before they can be granted roles
    }
  done

  step "Least-privilege permissions"
  # Web server: read the bucket, publish forbidden requests, write logs, connect to Cloud SQL.
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="serviceAccount:$SERVER_SA" --role=roles/storage.objectViewer >/dev/null
  gcloud pubsub topics add-iam-policy-binding "$TOPIC" \
    --member="serviceAccount:$SERVER_SA" --role=roles/pubsub.publisher >/dev/null
  for role in roles/logging.logWriter roles/cloudsql.client; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$SERVER_SA" --role="$role" --condition=None >/dev/null
  done
  # Forbidden service: only read from its subscription.
  gcloud pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" \
    --member="serviceAccount:$FORBIDDEN_SA" --role=roles/pubsub.subscriber >/dev/null
  # Watchdog: look at / stop Cloud SQL instances.
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$WATCHDOG_SA" --role=roles/cloudsql.editor --condition=None >/dev/null
  echo "done"
}

# ------------------------------------------------------------------ DB watchdog
setup_watchdog() {
  step "DB watchdog: Cloud Function + hourly Cloud Scheduler job"
  if exists gcloud functions describe "$FUNCTION" --region="$REGION" --gen2; then
    echo "$FUNCTION already deployed"
  else
    # Gen2 functions are built by Cloud Build using the default compute service account.
    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
      --role=roles/cloudbuild.builds.builder --condition=None >/dev/null
    gcloud functions deploy "$FUNCTION" --gen2 --region="$REGION" --runtime=python312 \
      --source=db_watchdog --entry-point=check_db --trigger-http --no-allow-unauthenticated \
      --service-account="$WATCHDOG_SA" --memory=256Mi --timeout=60s \
      --set-env-vars="PROJECT_ID=$PROJECT_ID,DB_INSTANCE=$DB_INSTANCE"
  fi
  # Scheduler calls the function as the watchdog service account.
  gcloud functions add-invoker-policy-binding "$FUNCTION" --region="$REGION" \
    --member="serviceAccount:$WATCHDOG_SA" >/dev/null 2>&1 || \
  gcloud run services add-iam-policy-binding "$FUNCTION" --region="$REGION" \
    --member="serviceAccount:$WATCHDOG_SA" --role=roles/run.invoker >/dev/null

  URL=$(gcloud functions describe "$FUNCTION" --region="$REGION" --gen2 --format='value(serviceConfig.uri)')
  if exists gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION"; then
    echo "$SCHEDULER_JOB already exists"
  else
    gcloud scheduler jobs create http "$SCHEDULER_JOB" --location="$REGION" \
      --schedule="0 * * * *" --time-zone="America/New_York" \
      --uri="$URL" --http-method=POST \
      --oidc-service-account-email="$WATCHDOG_SA" --oidc-token-audience="$URL"
  fi
  # We are about to use the database, so pause the watchdog until cleanup.sh resumes it.
  gcloud scheduler jobs pause "$SCHEDULER_JOB" --location="$REGION" --quiet >/dev/null 2>&1
  echo "Watchdog PAUSED while you work. cleanup.sh resumes it (or: bash watchdog.sh resume)."
}

# ------------------------------------------------------------------ Cloud SQL
wait_for_db() {
  echo -n "Waiting for $DB_INSTANCE to be ready"
  for _ in $(seq 1 120); do   # up to 20 minutes
    state=$(gcloud sql instances describe "$DB_INSTANCE" --format='value(state)' 2>/dev/null)
    busy=$(gcloud sql operations list --instance="$DB_INSTANCE" --filter='status!=DONE' \
             --format='value(name)' 2>/dev/null)
    if [ "$state" = "RUNNABLE" ] && [ -z "$busy" ]; then echo " ready"; return 0; fi
    echo -n "."; sleep 10
  done
  echo; echo "ERROR: $DB_INSTANCE did not become ready"; exit 1
}

create_schema() {
  echo "Creating database user + schema"
  if [ -n "$(gcloud sql users list --instance="$DB_INSTANCE" --filter="name=$DB_USER" --format='value(name)')" ]; then
    gcloud sql users set-password "$DB_USER" --instance="$DB_INSTANCE" --host=% --password="$DB_PASS"
  else
    gcloud sql users create "$DB_USER" --instance="$DB_INSTANCE" --host=% --password="$DB_PASS"
  fi
  ensure_venv
  DB_PASS="$DB_PASS" "$VENV/bin/python" setup_schema.py || { echo "ERROR: schema setup failed"; exit 1; }
}

setup_cloud_sql() {
  step "Cloud SQL ($DB_INSTANCE)"
  if exists gcloud sql instances describe "$DB_INSTANCE"; then
    echo "$DB_INSTANCE already exists -> starting it, skipping creation"
    gcloud sql instances patch "$DB_INSTANCE" --activation-policy=ALWAYS --quiet
    wait_for_db
    if exists gcloud sql databases describe "$DB_NAME" --instance="$DB_INSTANCE"; then
      echo "Database $DB_NAME already exists -> skipping schema setup"
    else
      create_schema
    fi
  else
    echo "$DB_INSTANCE does not exist -> creating it (takes ~5-10 minutes)"
    gcloud sql instances create "$DB_INSTANCE" --database-version=MYSQL_8_0 \
      --edition=enterprise --tier="$DB_TIER" --region="$REGION" \
      --storage-type=HDD --storage-size=10GB --availability-type=zonal \
      --no-backup --activation-policy=ALWAYS --root-password="$DB_PASS"
    wait_for_db
    create_schema
  fi
}

# ------------------------------------------------------------------ network
setup_network() {
  step "Static IP + firewall (port 80)"
  exists gcloud compute addresses describe "$IP_NAME" --region="$REGION" || \
    gcloud compute addresses create "$IP_NAME" --region="$REGION"
  SERVER_IP=$(server_ip)          # read the IP from gcloud - never hardcoded
  echo "Server IP: $SERVER_IP"
  exists gcloud compute firewall-rules describe "$FIREWALL_RULE" || \
    gcloud compute firewall-rules create "$FIREWALL_RULE" --allow=tcp:80 --target-tags="$NETWORK_TAG"
}

# ------------------------------------------------------------------ VMs
create_vm() {   # create_vm NAME <gcloud create args...>
  local name=$1; shift
  if exists gcloud compute instances describe "$name" --zone="$ZONE"; then
    echo "$name already exists"
    status=$(gcloud compute instances describe "$name" --zone="$ZONE" --format='value(status)')
    [ "$status" = "TERMINATED" ] && gcloud compute instances start "$name" --zone="$ZONE"
  else
    gcloud compute instances create "$name" --zone="$ZONE" "$@"
  fi
}

setup_vms() {
  step "Web server VM ($SERVER_MACHINE)"
  create_vm "$SERVER_VM" --machine-type="$SERVER_MACHINE" \
    --image-family=debian-12 --image-project=debian-cloud \
    --address="$SERVER_IP" --tags="$NETWORK_TAG" \
    --service-account="$SERVER_SA" --scopes=cloud-platform \
    --metadata="hw5-role=server,bucket-name=$BUCKET,topic-id=$TOPIC,db-connection=$DB_CONNECTION,db-name=$DB_NAME,db-user=$DB_USER,db-pass=$DB_PASS" \
    --metadata-from-file="startup-script=startup.sh,server-code=HW5.py,server-requirements=requirements-server.txt"

  step "Forbidden-country VM (Service 2)"
  create_vm "$FORBIDDEN_VM" --machine-type=e2-micro \
    --image-family=debian-12 --image-project=debian-cloud \
    --service-account="$FORBIDDEN_SA" --scopes=cloud-platform \
    --metadata="hw5-role=forbidden,subscription-id=$SUBSCRIPTION" \
    --metadata-from-file="startup-script=startup.sh,forbidden-code=forbidden_service.py"

  step "Client VM (runs the course http-client; no Google permissions needed)"
  create_vm "$CLIENT_VM" --machine-type=e2-small \
    --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
    --no-service-account --no-scopes \
    --metadata="hw5-role=client" \
    --metadata-from-file="startup-script=startup.sh,client-code=http-client.pyc.b64"
}

# ------------------------------------------------------------------ main
enable_apis
setup_pubsub
setup_service_accounts
setup_watchdog
setup_cloud_sql
setup_network
setup_vms

cat <<EOF

Done. The VMs finish installing in ~2-3 minutes.
  Server:        http://$SERVER_IP/
  Quick test:    curl http://$SERVER_IP/$WEB_DIR/1.html
  Step 4 demo:   bash demo.sh
  Step 5 load:   bash run_clients.sh start   (then: bash run_clients.sh status)
  Step 6 timing: bash get_timings.sh
  Step 7 stats:  bash stats.sh
  When done:     bash cleanup.sh            (stops the DB, deletes VMs + IP)
EOF
