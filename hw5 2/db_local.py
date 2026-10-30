"""Shared helper for the scripts you run on your own computer (setup_schema.py,
show_tables.py, stats.py). Opens a connection to the Cloud SQL instance with the
Cloud SQL Python Connector.

Credentials: uses Application Default Credentials if you have them; otherwise it
borrows a token from your normal `gcloud auth login`, so no extra login is needed.
"""
import os
import subprocess

import pymysql

PROJECT_ID = "solar-attic-508721-n0"
REGION = os.environ.get("REGION", "us-central1")
INSTANCE = os.environ.get("DB_INSTANCE", "hw5-db")
DB_NAME = os.environ.get("DB_NAME", "hw5")
DB_USER = os.environ.get("DB_USER", "hw5-user")
DB_PASS = os.environ.get("DB_PASS", "")
DB_URL = os.environ.get("DB_URL")  # local testing only, e.g. mysql+pymysql://root@localhost/hw5


def _credentials():
    import google.auth
    from google.auth.exceptions import DefaultCredentialsError
    try:
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        return creds
    except DefaultCredentialsError:
        from google.oauth2.credentials import Credentials
        token = subprocess.check_output(["gcloud", "auth", "print-access-token"],
                                        text=True, shell=(os.name == "nt")).strip()
        return Credentials(token=token)


def connect(database=DB_NAME):
    """Returns a pymysql connection. database=None connects without selecting a DB."""
    if DB_URL:  # local test database
        from sqlalchemy.engine import make_url
        u = make_url(DB_URL)
        return pymysql.connect(host=u.host or "localhost", user=u.username, password=u.password or "",
                               port=u.port or 3306, database=database, autocommit=True,
                               unix_socket=u.query.get("unix_socket"))
    from google.cloud.sql.connector import Connector
    connector = Connector(credentials=_credentials())
    kwargs = dict(user=DB_USER, password=DB_PASS, autocommit=True)
    if database:
        kwargs["db"] = database
    return connector.connect(f"{PROJECT_ID}:{REGION}:{INSTANCE}", "pymysql", **kwargs)


def print_table(cursor, sql, title=None):
    cursor.execute(sql)
    rows = cursor.fetchall()
    cols = [d[0] for d in cursor.description]
    widths = [max(len(str(c)), *(len(str(r[i])) for r in rows)) if rows else len(str(c))
              for i, c in enumerate(cols)]
    if title:
        print(f"\n{title}")
    line = "+" + "+".join("-" * (w + 2) for w in widths) + "+"
    print(line)
    print("| " + " | ".join(str(c).ljust(w) for c, w in zip(cols, widths)) + " |")
    print(line)
    for r in rows:
        print("| " + " | ".join(str(v).ljust(w) for v, w in zip(r, widths)) + " |")
    print(line)
    return rows
