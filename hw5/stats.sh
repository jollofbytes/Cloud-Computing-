#!/bin/bash
# HW5 step 7: run the statistics queries (stats.sql) against Cloud SQL.
#
#   bash stats.sh        prints the results and saves them to stats_output.txt

PROJECT_ID="solar-attic-508721-n0"
cd "$(dirname "$0")" || exit 1
source ./config.sh
ensure_venv
DB_PASS="$DB_PASS" "$VENV/bin/python" stats.py | tee stats_output.txt
