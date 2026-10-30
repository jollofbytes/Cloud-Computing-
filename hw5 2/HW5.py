"""HW5 Service 1: the HW4 web server, now recording every request in Cloud SQL.

Same behavior as HW4:
  GET  /folder/1.html                -> file comes from the URL path
  POST {"filename": "folder/1.html"} -> file comes from the request body
  other methods                      -> 501
  missing file                       -> 404
  forbidden country (X-country)      -> 400, logged CRITICAL, sent to Service 2 via Pub/Sub

New in HW5:
  * Every request goes into the `requests` table (country, client IP, gender, age,
    income, is_banned, time of day, requested file).
  * Requests that fail (anything other than 200) also go into `failed_requests`
    (time of request, requested file, error code).
  * Each stage of a request runs in its own function and is timed with
    time.perf_counter_ns():
        1. extract_request_info()  - read the request + its headers
        2. read_file()             - download the file from Cloud Storage
        3. send_reply()            - send the response to the client
        4. save_to_db()            - insert the row(s) into Cloud SQL
    Every request's timings go to a CSV file; a running summary is printed every
    SUMMARY_EVERY requests (visible on the VM's serial console, no SSH needed).
"""
import csv
import datetime
import json
import logging
import os
import statistics
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

import sqlalchemy
from google.api_core.exceptions import NotFound
from google.cloud import pubsub_v1, storage

BUCKET_NAME = os.environ.get("BUCKET_NAME", "cs528hww2")
PROJECT_ID = os.environ.get("PROJECT_ID", "solar-attic-508721-n0")
TOPIC_ID = os.environ.get("TOPIC_ID", "forbidden-requests")
PORT = int(os.environ.get("PORT", "80"))

# Cloud SQL settings (passed in by startup.sh)
DB_CONNECTION = os.environ.get("DB_CONNECTION", f"{PROJECT_ID}:us-central1:hw5-db")
DB_NAME = os.environ.get("DB_NAME", "hw5")
DB_USER = os.environ.get("DB_USER", "hw5-user")
DB_PASS = os.environ.get("DB_PASS", "")
DB_URL = os.environ.get("DB_URL")  # optional: plain SQLAlchemy URL, used for local testing only

TIMING_FILE = os.environ.get("TIMING_FILE", "/var/log/hw5/timings.csv")
SUMMARY_EVERY = int(os.environ.get("SUMMARY_EVERY", "5000"))
USE_CLOUD_LOGGING = os.environ.get("USE_CLOUD_LOGGING", "1") == "1"

FORBIDDEN_COUNTRIES = {
    "north korea", "iran", "cuba", "myanmar", "iraq",
    "libya", "sudan", "zimbabwe", "syria",
}

# ---------------------------------------------------------------- shared clients
# Created once at startup and shared by every request.
bucket = storage.Client(project=PROJECT_ID).bucket(BUCKET_NAME)
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

log = logging.getLogger("hw5-file-server")
log.setLevel(logging.INFO)
log.addHandler(logging.StreamHandler())
if USE_CLOUD_LOGGING:
    # Background transport: log entries are sent in batches by a helper thread,
    # so logging never slows down a request (HW4 sent one API call per log line).
    from google.cloud import logging as cloud_logging
    from google.cloud.logging.handlers import CloudLoggingHandler
    log.addHandler(CloudLoggingHandler(cloud_logging.Client(project=PROJECT_ID),
                                       name="hw5-file-server"))


def make_engine():
    """Connection pool to Cloud SQL. The Cloud SQL Python Connector authenticates with
    the VM's service account (needs roles/cloudsql.client), so there is no IP allow-list
    and no proxy to run."""
    pool = dict(pool_size=10, max_overflow=10, pool_timeout=30, pool_recycle=1800)
    if DB_URL:
        return sqlalchemy.create_engine(DB_URL, **pool)
    from google.cloud.sql.connector import Connector
    connector = Connector()
    return sqlalchemy.create_engine(
        "mysql+pymysql://",
        creator=lambda: connector.connect(DB_CONNECTION, "pymysql", user=DB_USER,
                                          password=DB_PASS, db=DB_NAME),
        **pool,
    )


engine = make_engine()

INSERT_REQUEST = sqlalchemy.text(
    "INSERT INTO requests (country, client_ip, gender, age, income, is_banned,"
    " time_of_day, requested_file, status_code)"
    " VALUES (:country, :client_ip, :gender, :age, :income, :is_banned,"
    " :time_of_day, :requested_file, :status_code)")
INSERT_FAILED = sqlalchemy.text(
    "INSERT INTO failed_requests (request_time, requested_file, error_code)"
    " VALUES (:request_time, :requested_file, :error_code)")


# ---------------------------------------------------------------- timing
STAGES = ("extract_headers", "read_file", "send_response", "db_insert")


class Timings:
    """Thread-safe store of per-request stage timings (milliseconds)."""

    def __init__(self, path):
        self.lock = threading.Lock()
        self.values = {s: [] for s in STAGES}
        self.count = 0
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        # header only if the file is new OR empty (an earlier run may have been
        # stopped before its buffered header reached disk)
        new_file = not os.path.exists(path) or os.path.getsize(path) == 0
        self.file = open(path, "a", newline="")
        self.csv = csv.writer(self.file)
        if new_file:
            self.csv.writerow(["timestamp", "method", "status", *[s + "_ms" for s in STAGES]])
            self.file.flush()

    def add(self, method, status, ms):
        with self.lock:
            self.count += 1
            for s in STAGES:
                if ms.get(s) is not None:
                    self.values[s].append(ms[s])
            self.csv.writerow([f"{time.time():.3f}", method, status,
                               *[("" if ms.get(s) is None else f"{ms[s]:.3f}") for s in STAGES]])
            if self.count % 1000 == 0:
                self.file.flush()
            if self.count % SUMMARY_EVERY == 0:
                self.file.flush()
                print(self.summary(), flush=True)

    def summary(self):
        lines = [f"TIMING summary after {self.count} requests (ms):"]
        for s in STAGES:
            v = self.values[s]
            if v:
                v_sorted = sorted(v)
                p95 = v_sorted[int(0.95 * (len(v_sorted) - 1))]
                lines.append(f"TIMING {s:15s} n={len(v):7d} mean={statistics.fmean(v):8.3f} "
                             f"median={statistics.median(v):8.3f} p95={p95:8.3f} "
                             f"max={v_sorted[-1]:8.3f} total_s={sum(v) / 1000:9.1f}")
        return "\n".join(lines)


timings = Timings(TIMING_FILE)


def timed(stage, ms, fn, *args):
    """Run fn(*args), store how long it took (ms) under ms[stage]."""
    start = time.perf_counter_ns()
    try:
        return fn(*args)
    finally:
        ms[stage] = (time.perf_counter_ns() - start) / 1e6


def parse_client_time(value):
    """X-time looks like '2026-10-27 13:00:00'. Returns a datetime, or None if absent/bad."""
    try:
        return datetime.datetime.strptime(value.strip(), "%Y-%m-%d %H:%M:%S")
    except (AttributeError, ValueError):
        return None


# ---------------------------------------------------------------- request handler
class FileServer(BaseHTTPRequestHandler):

    def log_message(self, *args):  # silence the default one-line-per-request stderr log
        pass

    # ----- stage 1: request + headers -----
    def extract_request_info(self):
        """Read everything we need from the request: the file name and the client headers."""
        h = self.headers
        country = (h.get("X-country") or "").strip()
        if self.command == "GET":
            filename = unquote(urlparse(self.path).path)
        elif self.command == "POST":
            filename = self.filename_from_body()
        else:
            filename = unquote(urlparse(self.path).path)
        return {
            "country": country or None,
            "client_ip": (h.get("X-client-IP") or "").strip() or self.client_address[0],
            "gender": (h.get("X-gender") or "").strip() or None,
            "age": (h.get("X-age") or "").strip() or None,
            "income": (h.get("X-income") or "").strip() or None,
            "is_banned": country.lower() in FORBIDDEN_COUNTRIES,
            "time_of_day": parse_client_time(h.get("X-time")),
            "requested_file": filename.lstrip("/")[:512],
            "request_time": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        }

    def filename_from_body(self):
        """POST: accept JSON {"filename": ...}, a form field filename=..., or the raw body."""
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace").strip()
        try:
            return str(json.loads(raw).get("filename", ""))
        except (ValueError, AttributeError):
            pass
        form = parse_qs(raw)
        if "filename" in form:
            return form["filename"][0]
        return raw

    # ----- stage 2: Cloud Storage -----
    @staticmethod
    def read_file(filename):
        """Download the file from the bucket. Returns bytes, or None if it doesn't exist."""
        try:
            return bucket.blob(filename).download_as_bytes()
        except (NotFound, ValueError):  # ValueError = empty filename
            return None

    # ----- stage 3: response -----
    def send_reply(self, status, body, content_type="text/plain"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":  # HEAD responses must not have a body
            self.wfile.write(body)

    # ----- stage 4: database -----
    @staticmethod
    def save_to_db(info, status):
        """One transaction: the request row, plus a failed_requests row if status != 200."""
        try:
            with engine.begin() as conn:
                conn.execute(INSERT_REQUEST, {**info, "status_code": status})
                if status != 200:
                    conn.execute(INSERT_FAILED, {"request_time": info["request_time"],
                                                 "requested_file": info["requested_file"],
                                                 "error_code": status})
        except Exception as e:  # never let a DB problem take the web server down
            log.error(f"DB insert failed: {e}")

    # ----- the pipeline every request goes through -----
    def handle_request(self):
        ms = {}
        info = timed("extract_headers", ms, self.extract_request_info)
        filename = info["requested_file"]

        if self.command not in ("GET", "POST"):
            status, body, ctype = 501, "501 Not Implemented", "text/plain"
            log.error(f"501 Not Implemented: {self.command} {self.path}")

        elif info["is_banned"]:
            status, ctype = 400, "text/plain"
            body = f"400 Permission denied: requests from {info['country']} are not allowed"
            msg = {"country": info["country"], "filename": filename, "method": self.command}
            log.critical(f"Forbidden request from {info['country']} for {filename}")
            publisher.publish(topic_path, json.dumps(msg).encode("utf-8"))  # batched, non-blocking

        else:
            content = timed("read_file", ms, self.read_file, filename)
            if content is None:
                status, body, ctype = 404, "404 Not Found", "text/plain"
                log.warning(f"404 Not Found: {filename}")
            else:
                status, body, ctype = 200, content, "text/html"

        timed("send_response", ms, self.send_reply, status, body, ctype)
        timed("db_insert", ms, self.save_to_db, info, status)
        timings.add(self.command, status, ms)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = do_OPTIONS = handle_request
    do_CONNECT = do_TRACE = handle_request


if __name__ == "__main__":
    print(f"Serving gs://{BUCKET_NAME} on port {PORT}, logging requests to "
          f"{DB_URL or DB_CONNECTION}", flush=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), FileServer)
    server.daemon_threads = True
    server.request_queue_size = 128
    # systemd stops the service with SIGTERM: turn it into a normal exit so the
    # finally block flushes the last buffered timing rows to disk
    import signal, sys
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        server.serve_forever()
    finally:
        with timings.lock:
            timings.file.flush()
        print(timings.summary(), flush=True)
