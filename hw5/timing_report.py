"""HW5 step 6: summarizes the per-request timings the web server recorded.

Copy the file off the server first (get_timings.sh does this), then:
    python timing_report.py timings.csv
"""
import csv
import statistics
import sys

STAGES = ("extract_headers", "read_file", "send_response", "db_insert")
LABELS = {
    "extract_headers": "Process request + extract headers",
    "read_file": "Read file from Cloud Storage",
    "send_response": "Send response to client",
    "db_insert": "Insert into database",
}

path = sys.argv[1] if len(sys.argv) > 1 else "timings.csv"
values = {s: [] for s in STAGES}
n = 0
with open(path) as f:
    for row in csv.DictReader(f):
        n += 1
        for s in STAGES:
            if row.get(s + "_ms"):
                values[s].append(float(row[s + "_ms"]))


def pct(v, p):
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


print(f"Requests timed: {n}\n")
header = f"{'Stage':36s} {'count':>8s} {'mean ms':>9s} {'median':>9s} {'p95':>9s} {'p99':>9s} {'max':>9s} {'total s':>9s}"
print(header)
print("-" * len(header))
for s in STAGES:
    v = sorted(values[s])
    if not v:
        continue
    print(f"{LABELS[s]:36s} {len(v):8d} {statistics.fmean(v):9.3f} {statistics.median(v):9.3f} "
          f"{pct(v, 95):9.3f} {pct(v, 99):9.3f} {v[-1]:9.3f} {sum(v) / 1000:9.1f}")
print("\nread_file only runs for requests that reach Cloud Storage "
      "(not banned-country or 501 requests).")
