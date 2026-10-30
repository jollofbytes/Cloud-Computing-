#!/bin/bash
# HW5 step 5: run 2 copies of the course http-client at the same time on the client
# VM, 50,000 requests each, both with the SAME random seed.
#
#   bash run_clients.sh start     start both clients (they keep running if you disconnect)
#   bash run_clients.sh status    how many responses each client has received so far
#   bash run_clients.sh results   status-code totals once they are done
#
# Settings: SEED, NUM (requests per client), MAX_INDEX (files in the bucket folder).

PROJECT_ID="solar-attic-508721-n0"
cd "$(dirname "$0")" || exit 1
source ./config.sh

SEED=${SEED:-528}
NUM=${NUM:-50000}
MAX_INDEX=${MAX_INDEX:-10000}
IP=$(server_ip)
on_client() { gcloud compute ssh "$CLIENT_VM" --zone="$ZONE" --command "$1"; }

case "${1:-status}" in
  start)
    echo "Starting 2 clients -> $IP  (seed=$SEED, $NUM requests each)"
    on_client "mkdir -p ~/hw5 && cd ~/hw5 && rm -f client*.log && date -u > started_at.txt &&
      for i in 1 2; do
        nohup bash -c 'http-client -d $IP -p 80 -b none -w $WEB_DIR -n $NUM -i $MAX_INDEX -r $SEED -v 2>&1 \
          | grep -aE \"^[0-9]{3} |Timeout|Error|Traceback\" > client\$0.log; date -u > done\$0.txt' \$i >/dev/null 2>&1 &
      done; sleep 2; echo started"
    ;;
  status)
    on_client "cd ~/hw5 && echo started: \$(cat started_at.txt) &&
      for i in 1 2; do echo client \$i: \$(grep -caE '^[0-9]{3} ' client\$i.log) responses \
        \$( [ -f done\$i.txt ] && echo '- DONE at' \$(cat done\$i.txt) ); done"
    ;;
  results)
    on_client "cd ~/hw5 && for i in 1 2; do echo '-- client' \$i; sort client\$i.log | uniq -c | sort -rn; done"
    ;;
  *) echo "Use: start | status | results"; exit 1 ;;
esac
