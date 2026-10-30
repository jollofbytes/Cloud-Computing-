#!/bin/bash
# HW5 step 8: control the hourly database watchdog.
#
#   bash watchdog.sh pause    turn it off while you are actively using the database
#   bash watchdog.sh resume   turn it back on when you are done
#   bash watchdog.sh run      run the check right now (stops the DB if it is on)
#   bash watchdog.sh status   is the schedule on, and is the DB running?

PROJECT_ID="solar-attic-508721-n0"
cd "$(dirname "$0")" || exit 1
source ./config.sh

case "${1:-status}" in
  pause)  gcloud scheduler jobs pause  "$SCHEDULER_JOB" --location="$REGION" ;;
  resume) gcloud scheduler jobs resume "$SCHEDULER_JOB" --location="$REGION" ;;
  run)    gcloud scheduler jobs run    "$SCHEDULER_JOB" --location="$REGION"
          echo "Triggered. Function log:"; sleep 20
          gcloud functions logs read "$FUNCTION" --region="$REGION" --gen2 --limit=5 ;;
  status) ;;
  *) echo "Use: pause | resume | run | status"; exit 1 ;;
esac

echo "Schedule: $(gcloud scheduler jobs describe "$SCHEDULER_JOB" --location="$REGION" --format='value(state,schedule)')"
echo "Database: $(gcloud sql instances describe "$DB_INSTANCE" --format='value(state,settings.activationPolicy)')"
