import json
import os

import functions_framework
from google.api_core.exceptions import NotFound
from google.cloud import pubsub_v1, storage

# Set these when you deploy (--set-env-vars)
BUCKET_NAME = os.environ["Bucket_Name"]
PROJECT_ID = os.environ["Project_ID"]
TOPIC_ID = os.environ["Topic_ID"]

FORBIDDEN_COUNTRIES = {
    "north korea", "iran", "cuba", "myanmar", "iraq",
    "libya", "sudan", "zimbabwe", "syria",
}

# Created once per instance, reused across requests
storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET_NAME)
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)


def log_error(message, **fields):
    """Log twice: a simple print, and a structured (JSON) log."""
    print(message)
    print(json.dumps({"severity": "ERROR", "message": message, **fields}))


@functions_framework.http
def file_server(request):
    method = request.method

    # 501: anything other than GET or POST
    if method not in ("GET", "POST"):
        log_error(f"501 Not Implemented: {method} {request.path}",
                  status=501, method=method, path=request.path)
        return "501 Not Implemented", 501

    # Get the filename: from the path (GET) or the body (POST)
    if method == "GET":
        filename = request.path.lstrip("/")
    else:
        body = request.get_json(silent=True) or {}
        filename = body.get("filename") or request.form.get("filename", "")

    # 400: request from a forbidden country -> tell Service 2 via Pub/Sub
    country = request.headers.get("X-country", "").strip()
    if country.lower() in FORBIDDEN_COUNTRIES:
        msg = {"country": country, "filename": filename, "method": method}
        publisher.publish(topic_path, json.dumps(msg).encode("utf-8")).result()
        print(f"Forbidden request from {country} for {filename}")
        return f"400 Permission denied: requests from {country} are not allowed", 400

    # 200 or 404: look up the file in the bucket
    try:
        content = bucket.blob(filename).download_as_bytes()
    except (NotFound, ValueError):
        log_error(f"404 Not Found: {filename}",
                  status=404, method=method, filename=filename)
        return "404 Not Found", 404

    return content, 200, {"Content-Type": "text/html"}
