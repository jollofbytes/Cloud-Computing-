#!/bin/bash
# HW5 step 6: copy the per-request timing file off the web server and summarize it.
#
#   bash get_timings.sh           full report from timings.csv
#   bash get_timings.sh console   just the running TIMING summaries (serial console, no SSH)

PROJECT_ID="solar-attic-508721-n0"
cd "$(dirname "$0")" || exit 1
source ./config.sh

if [ "$1" = "console" ]; then
  gcloud compute instances get-serial-port-output "$SERVER_VM" --zone="$ZONE" 2>/dev/null \
    | grep -a "TIMING" | tail -5
  exit 0
fi

gcloud compute scp "$SERVER_VM:/var/log/hw5/timings.csv" ./timings.csv --zone="$ZONE" || exit 1
ensure_venv
"$VENV/bin/python" timing_report.py timings.csv | tee timing_report.txt
