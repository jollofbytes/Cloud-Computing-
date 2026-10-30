# CS528 HW5 — Web server + Cloud SQL

Builds on HW4: the same file server (now `HW5.py`) records every request in Cloud SQL,
times each stage of request handling, and an hourly watchdog stops the database
when nobody is using it.

## Files

| File | What it is |
|---|---|
| `HW5.py` | **App 1 (modified)**: HW4 web server + DB inserts + per-stage timing |
| `forbidden_service.py` | **App 2 (unmodified)**: prints forbidden-country requests from Pub/Sub |
| `db_watchdog/main.py` | **Cloud Function**: stops Cloud SQL if it is running |
| `setup.sh` / `cleanup.sh` | Create / tear down everything (graded) |
| `startup.sh` | VM startup script for all 3 VMs (run-once, role chosen by VM metadata) |
| `schema.sql` + `setup_schema.py` | Database schema, applied by `setup.sh` on first run |
| `config.sh` | Shared names/settings (project ID hardcoded) |
| `demo.sh` | Step 4: curl demo, tables shown before/after each request |
| `run_clients.sh` | Step 5: 2 clients × 50,000 requests, same seed |
| `get_timings.sh` + `timing_report.py` | Step 6: timing results |
| `stats.sh` + `stats.sql` + `stats.py` | Step 7: statistics |
| `watchdog.sh` | Step 8: pause / resume / test the watchdog |
| `http-client.pyc.b64` | The new (HW5) course client, as Python 3.12 bytecode, for the client VM |

## Architecture

```
 hw5-client VM ──HTTP──▶ hw5-server VM (HW5.py, static IP, port 80)
 (2 × http-client)          │  read file ──────▶ Cloud Storage (cs528hww2)
                            │  insert rows ────▶ Cloud SQL MySQL (hw5-db)
                            │  banned country ─▶ Pub/Sub ──▶ hw5-forbidden VM (forbidden_service.py)

 Cloud Scheduler (every hour) ──▶ Cloud Function hw5-db-watchdog ──▶ stops hw5-db if running
```

- The server connects to Cloud SQL with the **Cloud SQL Python Connector**, authenticated by
  the VM's service account (`roles/cloudsql.client`): no IP allow-list, no proxy process.
- Each VM has its own service account with only the permissions it needs.

## Database schema

`requests`: one row per request received (all requests, including failures).

| Column | Type | Source |
|---|---|---|
| `request_id` | BIGINT, **PK**, auto-increment | |
| `country` | VARCHAR(64) | `X-country` header |
| `client_ip` | VARCHAR(45) | `X-client-IP` header |
| `gender` | VARCHAR(16) | `X-gender` |
| `age` | VARCHAR(16) | `X-age` (0-16 … 76+) |
| `income` | VARCHAR(16) | `X-income` (0-10k … 250k+) |
| `is_banned` | BOOLEAN | computed: country is on the forbidden list |
| `time_of_day` | DATETIME | `X-time` (e.g. `2026-10-27 13:00:00`) |
| `requested_file` | VARCHAR(512) | URL path (GET) or body (POST) |
| `status_code` | SMALLINT | response sent |
| `received_at` | TIMESTAMP(3) | server clock |

`failed_requests`: one row per non-200 response.

| Column | Type |
|---|---|
| `failure_id` | BIGINT, **PK**, auto-increment |
| `request_time` | DATETIME(3), when the server received it (UTC) |
| `requested_file` | VARCHAR(512) |
| `error_code` | SMALLINT (400 / 404 / 501) |

The client's headers were found by disassembling the course client (`build_headers()` sets
`X-country`, `X-client-IP`, `X-gender`, `X-age`, `X-income`, `X-time`). There is no
banned header, so the server computes `is_banned` from its forbidden-country list.

## How to run

Requirements: `gcloud` logged in (`gcloud auth login`) with Owner/Editor on the project,
`python3`, and the HW2 bucket. All commands run from this `hw5/` folder.

> **Database password (graders, please read):** the real password for the `hw5-user`
> database user is intentionally **not** in this public repo. `config.sh` holds a placeholder.
> Before running `setup.sh`, pass the real password as an environment variable:
>
> ```bash
> DB_PASS='<password>' bash setup.sh
> ```
>
> I'm happy to share the password privately (e.g. by email or Piazza DM). Without it the
> server still starts and serves files, but its database inserts fail with "Access denied".
> Alternatively, reset it yourself: `gcloud sql users set-password hw5-user --instance=hw5-db
> --host=% --password='<new password>'`, then run `DB_PASS='<new password>' bash setup.sh`.

```bash
bash setup.sh                 # ~10 min the first time (Cloud SQL creation), ~2 min after
bash demo.sh                  # step 4 - screenshot this output
bash run_clients.sh start     # step 5 - 2 clients x 50,000 requests, seed 528
bash run_clients.sh status    #   check progress (repeat until both say DONE)
bash run_clients.sh results   #   status-code totals per client
bash get_timings.sh           # step 6 - timing table (also saved to timing_report.txt)
bash stats.sh                 # step 7 - statistics (also saved to stats_output.txt)
bash cleanup.sh               # delete VMs + IP + firewall, STOP the DB, re-enable watchdog
```

What `setup.sh` does, in order:
1. Enables the APIs (Compute, Cloud SQL Admin, Pub/Sub, Functions, Scheduler, …).
2. Creates the Pub/Sub topic + subscription.
3. Creates 3 service accounts and grants least-privilege roles.
4. Deploys the watchdog function + hourly schedule, then **pauses** it while you work.
5. Cloud SQL: if `hw5-db` exists, **starts** it and skips creation (and skips the schema if
   database `hw5` exists); otherwise creates it, creates the DB user, and runs
   `setup_schema.py`.
6. Reserves the static IP and reads its value with `gcloud` (never hardcoded); opens port 80.
7. Creates the 3 VMs with `startup.sh` attached via `--metadata-from-file startup-script=…`.
   `startup.sh` installs packages, pulls the code from VM metadata, and starts the apps as
   systemd services. A lock file (`/var/log/startup_already_done`) stops it from re-running.

## Database watchdog (step 8)

A Cloud Function can't run on a timer by itself; something has to trigger it. **Cloud
Scheduler** calls it every hour (`0 * * * *`). The function reads the instance's `state`
and `activationPolicy` from the Cloud SQL Admin API. If the policy is `ALWAYS` (running), it
sets it to `NEVER`, which stops the instance without deleting it, and logs what it did.

```bash
bash watchdog.sh pause    # while actively using the DB (setup.sh does this for you)
bash watchdog.sh resume   # when done (cleanup.sh does this for you)
bash watchdog.sh run      # trigger a check now, then show the function's log
bash watchdog.sh status
```

## Timing (step 6)

Each request runs through four functions in `HW5.py`, each timed with
`time.perf_counter_ns()`:

| Stage | Function |
|---|---|
| Process request + extract headers | `extract_request_info()` |
| Read file from Cloud Storage | `read_file()` |
| Send response to client | `send_reply()` |
| Insert into database | `save_to_db()` |

Every request's timings are appended to `/var/log/hw5/timings.csv` on the server. A summary
is also printed every 5,000 requests to the serial console (`bash get_timings.sh console`).
The response is sent **before** the DB insert, so the client never waits on the database.

## Report checklist (PDF)

- [ ] Setup/run steps (sections above)
- [ ] Database schema (tables above, or `setup_schema.py` output)
- [ ] Step 4 screenshots from `demo.sh`
- [ ] Step 6 table from `timing_report.txt`
- [ ] Step 7 answers from `stats_output.txt`
- [ ] Watchdog: Cloud Scheduler + Cloud Function (document the choice)
- [ ] Billing: `billing_report.pdf` the day after the deadline

Note: both clients use the same seed, so they send the same sequence of requests and
every count in step 7 covers 100,000 requests (2 × 50,000).
