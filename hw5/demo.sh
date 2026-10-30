#!/bin/bash
# HW5 step 4: one successful + two failing curl requests, showing both tables
# before and after each one. Take your screenshots from this output.
#
#   bash demo.sh

PROJECT_ID="solar-attic-508721-n0"
cd "$(dirname "$0")" || exit 1
source ./config.sh
ensure_venv

IP=$(server_ip)
URL="http://$IP/$WEB_DIR"
show() { DB_PASS="$DB_PASS" "$VENV/bin/python" show_tables.py 3; }
run()  { echo; echo "\$ $*"; "$@"; echo; }

echo "################ BEFORE any request"
show

echo; echo "################ REQUEST 1: valid file, allowed country -> expect 200"
run curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -H "X-country: Nigeria" -H "X-client-IP: 102.89.12.34" -H "X-gender: Female" \
  -H "X-age: 26-35" -H "X-income: 60k-100k" -H "X-time: $(date +%F) 14:00:00" \
  "$URL/1.html"
show

echo; echo "################ REQUEST 2: file that does not exist -> expect 404"
run curl -s -w "  (HTTP %{http_code})\n" \
  -H "X-country: Canada" -H "X-client-IP: 24.48.1.9" -H "X-gender: Male" \
  -H "X-age: 17-25" -H "X-income: 20k-40k" -H "X-time: $(date +%F) 09:00:00" \
  "$URL/does-not-exist-99999.html"
show

echo; echo "################ REQUEST 3: banned country -> expect 400"
run curl -s -w "  (HTTP %{http_code})\n" \
  -H "X-country: Iran" -H "X-client-IP: 5.160.1.1" -H "X-gender: Male" \
  -H "X-age: 36-45" -H "X-income: 10k-20k" -H "X-time: $(date +%F) 21:00:00" \
  "$URL/1.html"
show
