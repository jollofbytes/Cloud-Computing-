"""HW5 step 8: Cloud Function that stops the Cloud SQL instance if it is running.

Cloud Scheduler calls it every hour (job hw5-db-watchdog-hourly). It does not delete
anything: it sets the instance's activation policy to NEVER, which is what
`gcloud sql instances patch --activation-policy=NEVER` (i.e. "Stop") does.

While you are actively using the database, pause the schedule:
    bash watchdog.sh pause      ...and when done:  bash watchdog.sh resume
"""
import json
import os

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession

PROJECT_ID = os.environ.get("PROJECT_ID", "solar-attic-508721-n0")
INSTANCE = os.environ.get("DB_INSTANCE", "hw5-db")
API = f"https://sqladmin.googleapis.com/v1/projects/{PROJECT_ID}/instances/{INSTANCE}"

credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(credentials)


def log(message, **fields):
    print(json.dumps({"severity": "INFO", "message": message, **fields}), flush=True)


@functions_framework.http
def check_db(request):
    resp = session.get(API)
    if resp.status_code == 404:
        log(f"{INSTANCE} does not exist, nothing to do")
        return f"{INSTANCE} does not exist\n", 200
    resp.raise_for_status()

    instance = resp.json()
    state = instance.get("state")                                   # RUNNABLE, STOPPED, ...
    policy = instance.get("settings", {}).get("activationPolicy")   # ALWAYS = on, NEVER = off

    if policy == "ALWAYS":
        op = session.patch(API, json={"settings": {"activationPolicy": "NEVER"}})
        op.raise_for_status()
        log(f"{INSTANCE} was running (state={state}); stopping it",
            instance=INSTANCE, state=state, action="stop", operation=op.json().get("name"))
        return f"{INSTANCE} was running (state={state}) - stop requested\n", 200

    log(f"{INSTANCE} is not running (state={state}, policy={policy}); nothing to do",
        instance=INSTANCE, state=state, action="none")
    return f"{INSTANCE} is not running (state={state}, policy={policy})\n", 200
