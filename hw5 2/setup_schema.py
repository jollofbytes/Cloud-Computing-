"""Creates the HW5 database tables (called by setup.sh the first time the
Cloud SQL instance is created). Safe to rerun: every statement is IF NOT EXISTS.

    DB_PASS=... python setup_schema.py
"""
import os

from db_local import connect

SCHEMA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")


def main():
    with open(SCHEMA_FILE) as f:
        # drop comment lines, then split into statements on ';'
        sql = "\n".join(line for line in f if not line.strip().startswith("--"))
    statements = [s.strip() for s in sql.split(";") if s.strip()]

    conn = connect(database=None)
    with conn.cursor() as cur:
        for stmt in statements:
            print("  >", stmt.splitlines()[0])
            cur.execute(stmt)
        cur.execute("SHOW TABLES")
        print("Tables in hw5:", ", ".join(r[0] for r in cur.fetchall()))
        for table in ("requests", "failed_requests"):
            cur.execute(f"SHOW CREATE TABLE {table}")
            print("\n" + cur.fetchone()[1])
    conn.close()


if __name__ == "__main__":
    main()
