"""CS528 HW6 part 2: move the HW5 data into the 3NF schema.

    python migrate.py

1. Creates database hw6 and its tables (schema_3nf.sql). Safe to rerun.
2. Checks the data really has "one country per IP" and "one is_banned per country".
3. If hw6 is still empty, copies the data (migrate.sql) in ONE transaction:
   if any step fails, nothing is kept.
4. Checks that no row was lost: the row counts must match.
The old hw5 tables are only read, never changed.
"""
import os
import sys

import db

HERE = os.path.dirname(os.path.abspath(__file__))


def one_value(cur, sql):
    cur.execute(sql)
    return cur.fetchone()[0]


def main():
    conn = db.connect()
    cur = conn.cursor()

    print("== Creating the 3NF schema (database hw6) ==")
    for stmt in db.read_sql_file(os.path.join(HERE, "schema_3nf.sql")):
        cur.execute(stmt)
    conn.commit()

    print("== Checking the dependencies the new schema relies on ==")
    ips_with_two_countries = one_value(cur, """
        SELECT COUNT(*) FROM (SELECT client_ip FROM hw5.requests
                              WHERE country IS NOT NULL
                              GROUP BY client_ip HAVING COUNT(DISTINCT country) > 1) t""")
    countries_with_two_flags = one_value(cur, """
        SELECT COUNT(*) FROM (SELECT country FROM hw5.requests WHERE country IS NOT NULL
                              GROUP BY country HAVING COUNT(DISTINCT is_banned) > 1) t""")
    print(f"IPs with more than one country:       {ips_with_two_countries}")
    print(f"Countries with more than one is_banned: {countries_with_two_flags}")
    if ips_with_two_countries or countries_with_two_flags:
        print("WARNING: the data breaks a dependency; MIN()/MAX() in migrate.sql picks one value.")

    already = one_value(cur, "SELECT COUNT(*) FROM hw6.requests")
    if already:
        print(f"== hw6 already has {already} requests -> skipping the copy ==")
    else:
        print("== Copying hw5 -> hw6 (one transaction) ==")
        try:
            for stmt in db.read_sql_file(os.path.join(HERE, "migrate.sql")):
                cur.execute(stmt)
                print(f"  {cur.rowcount:>7} rows  <- {stmt.splitlines()[0]}")
            conn.commit()
        except Exception:
            conn.rollback()
            raise

    print("== Row counts: old (hw5) vs new (hw6) ==")
    checks = [
        ("requests", "SELECT COUNT(*) FROM hw5.requests", "SELECT COUNT(*) FROM hw6.requests"),
        ("failed_requests", "SELECT COUNT(*) FROM hw5.failed_requests",
         "SELECT COUNT(*) FROM hw6.failed_requests"),
        ("distinct countries", "SELECT COUNT(DISTINCT country) FROM hw5.requests",
         "SELECT COUNT(*) FROM hw6.countries"),
        ("distinct client IPs", "SELECT COUNT(DISTINCT client_ip) FROM hw5.requests",
         "SELECT COUNT(*) FROM hw6.client_ips"),
        ("banned-country requests", "SELECT COUNT(*) FROM hw5.requests WHERE is_banned",
         "SELECT COUNT(*) FROM hw6.request_details WHERE is_banned"),
    ]
    ok = True
    for name, old_sql, new_sql in checks:
        old, new = one_value(cur, old_sql), one_value(cur, new_sql)
        ok &= old == new
        print(f"  {name:<24} hw5={old:<8} hw6={new:<8} {'OK' if old == new else 'MISMATCH'}")
    conn.close()
    db.close()
    if not ok:
        sys.exit("Migration check FAILED: row counts differ")
    print("Migration check passed: no rows lost.")


if __name__ == "__main__":
    main()
