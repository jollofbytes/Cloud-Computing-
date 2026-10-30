"""Prints row counts and the latest rows of both tables (used by demo.sh for step 4).

    python show_tables.py [number_of_rows]
"""
import sys

from db_local import connect, print_table

N = int(sys.argv[1]) if len(sys.argv) > 1 else 5

conn = connect()
with conn.cursor() as cur:
    print_table(cur, "SELECT (SELECT COUNT(*) FROM requests) AS requests_rows,"
                     " (SELECT COUNT(*) FROM failed_requests) AS failed_requests_rows",
                "Row counts")
    print_table(cur, f"SELECT * FROM (SELECT request_id, country, client_ip, gender, age, income,"
                     f" is_banned, time_of_day, requested_file, status_code FROM requests"
                     f" ORDER BY request_id DESC LIMIT {N}) t ORDER BY request_id",
                f"requests (latest {N})")
    print_table(cur, f"SELECT * FROM (SELECT * FROM failed_requests"
                     f" ORDER BY failure_id DESC LIMIT {N}) t ORDER BY failure_id",
                f"failed_requests (latest {N})")
conn.close()
