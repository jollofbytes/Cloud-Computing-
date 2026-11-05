"""Opens a connection to the Cloud SQL database (used by migrate.py and models.py).

On the VM it uses the Cloud SQL Python Connector, which logs in as the VM's
service account (role Cloud SQL Client) - no IP allow-list, no proxy.
Settings come from environment variables that startup.sh sets from the VM metadata.

Local testing only: set DB_HOST (and DB_PORT) to use a local MySQL server instead.
"""
import os

import pymysql

PROJECT_ID = os.environ.get("PROJECT_ID", "solar-attic-508721-n0")
REGION = os.environ.get("REGION", "us-central1")
DB_INSTANCE = os.environ.get("DB_INSTANCE", "hw5-db")
DB_USER = os.environ.get("DB_USER", "hw5-user")
DB_PASS = os.environ.get("DB_PASS", "")
DB_HOST = os.environ.get("DB_HOST")  # local testing only, e.g. 127.0.0.1
DB_PORT = int(os.environ.get("DB_PORT", "3306"))

_connector = None


def connect(database=None):
    """Returns a pymysql connection (autocommit off). database=None selects no database."""
    global _connector
    kwargs = dict(user=DB_USER, password=DB_PASS, autocommit=False)
    if database:
        kwargs["database"] = database
    if DB_HOST:
        return pymysql.connect(host=DB_HOST, port=DB_PORT, **kwargs)
    from google.cloud.sql.connector import Connector
    if _connector is None:
        _connector = Connector()
    return _connector.connect(f"{PROJECT_ID}:{REGION}:{DB_INSTANCE}", "pymysql", **kwargs)


def close():
    if _connector is not None:
        _connector.close()


def read_sql_file(path):
    """Splits a .sql file into statements (comment lines dropped, split on ';')."""
    with open(path) as f:
        sql = "\n".join(line for line in f if not line.strip().startswith("--"))
    return [s.strip() for s in sql.split(";") if s.strip()]
