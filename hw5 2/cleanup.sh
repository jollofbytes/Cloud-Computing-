#!/bin/bash
# CS528 HW5 - tears down what setup.sh created so nothing keeps billing.
#
#   bash cleanup.sh         delete the 3 VMs, release the static IP, delete the firewall
#                           rule, STOP (not delete) Cloud SQL, and turn the hourly
#                           DB watchdog back on.
#   bash cleanup.sh --all   same, plus delete the watchdog function + schedule,
#                           the service accounts, and the Pub/Sub topic/subscription.
#
# Cloud SQL is never deleted, only stopped (assignment requirement).
# No `gcloud auth application-default login` is used anywhere in HW5, so there is
# nothing to revoke.

PROJECT_ID="solar-attic-508721-n0"   # hardcoded on purpose - see config.sh
cd "$(dirname "$0")" || exit 1
source ./config.sh

step "Deleting VMs"
for vm in "$SERVER_VM" "$FORBIDDEN_VM" "$CLIENT_VM"; do
  if exists gcloud compute instances describe "$vm" --zone="$ZONE"; then
    gcloud compute instances delete "$vm" --zone="$ZONE" --quiet
  else
    echo "$vm not found"
  fi
done

step "Releasing static IP"
if exists gcloud compute addresses describe "$IP_NAME" --region="$REGION"; then
  gcloud compute addresses delete "$IP_NAME" --region="$REGION" --quiet
else
  echo "$IP_NAME not found"
fi

step "Deleting firewall rule"
if exists gcloud compute firewall-rules describe "$FIREWALL_RULE"; then
  gcloud compute firewall-rules delete "$FIREWALL_RULE" --quiet
else
  echo "$FIREWALL_RULE not found"
fi

step "Stopping Cloud SQL (not deleting)"
if exists gcloud sql instances describe "$DB_INSTANCE"; then
  gcloud sql instances patch "$DB_INSTANCE" --activation-policy=NEVER --quiet
  gcloud sql instances describe "$DB_INSTANCE" --format='value(state,settings.activationPolicy)'
else
  echo "$DB_INSTANCE not found"
fi

if [ "$1" = "--all" ]; then
  step "Deleting DB watchdog (schedule + function)"
  exists gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION" && \
    gcloud scheduler jobs delete "$SCHEDULER_JOB" --location="$REGION" --quiet
  exists gcloud functions describe "$FUNCTION" --region="$REGION" --gen2 && \
    gcloud functions delete "$FUNCTION" --region="$REGION" --gen2 --quiet

  step "Deleting Pub/Sub subscription + topic"
  exists gcloud pubsub subscriptions describe "$SUBSCRIPTION" && \
    gcloud pubsub subscriptions delete "$SUBSCRIPTION" --quiet
  exists gcloud pubsub topics describe "$TOPIC" && gcloud pubsub topics delete "$TOPIC" --quiet

  step "Deleting service accounts"
  for sa in "$SERVER_SA" "$FORBIDDEN_SA" "$WATCHDOG_SA"; do
    exists gcloud iam service-accounts describe "$sa" && \
      gcloud iam service-accounts delete "$sa" --quiet
  done
else
  step "Re-enabling the hourly DB watchdog"
  if exists gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION"; then
    gcloud scheduler jobs resume "$SCHEDULER_JOB" --location="$REGION" --quiet >/dev/null
    echo "Watchdog is ON (checks every hour)"
  else
    echo "$SCHEDULER_JOB not found"
  fi
fi

echo; echo "Cleanup finished."
