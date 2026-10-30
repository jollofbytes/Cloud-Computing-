"""HW5 step 7: runs every query in stats.sql and prints the results as tables.

    DB_PASS=... python stats.py | tee stats_output.txt
"""
import os

from db_local import connect, print_table

SQL_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stats.sql")


def queries():
    """Yields (title, sql) for each '-- Qn. title' block in stats.sql."""
    title, lines = None, []
    with open(SQL_FILE) as f:
        for line in f:
            if line.startswith("-- Q"):
                title, lines = line[3:].strip(), []
            elif title and not line.startswith("--"):
                lines.append(line)
                if line.rstrip().endswith(";"):
                    yield title, "".join(lines).strip().rstrip(";")
                    title = None


conn = connect()
with conn.cursor() as cur:
    for title, sql in queries():
        print_table(cur, sql, title)
conn.close()
