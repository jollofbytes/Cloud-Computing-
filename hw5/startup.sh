#!/bin/bash
# HW5 VM startup script. setup.sh attaches it to all three VMs with
#   --metadata-from-file startup-script=startup.sh
# and a metadata value `hw5-role` tells it which VM it is on:
#   server     -> HW5.py web server (Cloud Storage + Pub/Sub + Cloud SQL)
#   forbidden  -> forbidden_service.py (Service 2, unchanged from HW4)
#   client     -> the course http-client
# Runs as root, so no sudo. Runs once: later boots skip it (the systemd services
# installed below start on their own at every boot).

if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi
set -e

MD=http://metadata.google.internal/computeMetadata/v1
md()   { curl -sf -H "Metadata-Flavor: Google" "$MD/$1"; }
attr() { md "instance/attributes/$1"; }

ROLE=$(attr hw5-role)
PROJECT_ID=$(md project/project-id)
echo "HW5 startup: role=$ROLE project=$PROJECT_ID"

# Wait (up to 5 min) if another installer, e.g. the Ops Agent, is running at boot
APT="apt-get -o DPkg::Lock::Timeout=300"
$APT update -y

case "$ROLE" in
  server)
    APP_DIR=/opt/hw5-server
    $APT install -y python3-venv
    mkdir -p "$APP_DIR" /var/log/hw5
    python3 -m venv "$APP_DIR/venv"
    attr server-requirements > "$APP_DIR/requirements.txt"
    "$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
    attr server-code > "$APP_DIR/main.py"

    cat > /etc/systemd/system/hw5-server.service <<EOF
[Unit]
Description=CS528 HW5 file server
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/main.py
Environment=PROJECT_ID=$PROJECT_ID
Environment=BUCKET_NAME=$(attr bucket-name)
Environment=TOPIC_ID=$(attr topic-id)
Environment=DB_CONNECTION=$(attr db-connection)
Environment=DB_NAME=$(attr db-name)
Environment=DB_USER=$(attr db-user)
Environment=DB_PASS=$(attr db-pass)
Environment=TIMING_FILE=/var/log/hw5/timings.csv
Environment=PORT=80
Environment=PYTHONUNBUFFERED=1
# stdout (incl. the TIMING summaries) goes to the system log AND the serial console
StandardOutput=journal+console
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hw5-server
    systemctl restart hw5-server
    ;;

  forbidden)
    APP_DIR=/opt/hw5-forbidden
    $APT install -y python3-venv
    mkdir -p "$APP_DIR"
    python3 -m venv "$APP_DIR/venv"
    "$APP_DIR/venv/bin/pip" install -q google-cloud-pubsub
    attr forbidden-code > "$APP_DIR/forbidden_service.py"

    cat > /etc/systemd/system/hw5-forbidden.service <<EOF
[Unit]
Description=CS528 HW5 forbidden-country reporter (Service 2)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python3 $APP_DIR/forbidden_service.py
Environment=PROJECT_ID=$PROJECT_ID
Environment=SUBSCRIPTION_ID=$(attr subscription-id)
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal+console
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hw5-forbidden
    systemctl restart hw5-forbidden
    ;;

  client)
    # The course client is Python 3.12 bytecode (pulled out of the official binary);
    # Ubuntu 24.04 ships Python 3.12. certifi is its only extra dependency.
    $APT install -y python3-certifi
    mkdir -p /opt/http-client
    attr client-code | base64 -d > /opt/http-client/http-client.pyc
    cat > /usr/local/bin/http-client <<'EOF'
#!/bin/bash
exec python3 /opt/http-client/http-client.pyc "$@"
EOF
    chmod +x /usr/local/bin/http-client
    ;;

  *)
    echo "Unknown hw5-role '$ROLE' - nothing to do"
    exit 1
    ;;
esac

touch /var/log/startup_already_done
echo "HW5 startup ($ROLE) finished"
