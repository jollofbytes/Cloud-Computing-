"""HW4 Service 2: listens for forbidden-country requests and prints them.

Runs on its own VM. No key file or impersonation needed: on a VM, the Google
libraries automatically use the VM's service account (hw4-forbidden-sa).
"""
import datetime
import json
import os

from google.cloud import pubsub_v1

PROJECT_ID = os.environ.get("PROJECT_ID", "solar-attic-508721-n0")
SUBSCRIPTION_ID = os.environ.get("SUBSCRIPTION_ID", "forbidden-requests-sub")

subscriber = pubsub_v1.SubscriberClient()
subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)


def callback(message):
    try:
        data = json.loads(message.data.decode("utf-8"))
        now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        print(f"{now} FORBIDDEN: {data.get('method')} request from "
              f"{data.get('country')} for {data.get('filename')} was denied", flush=True)
    except Exception as e:
        print(f"Could not read message: {e}", flush=True)
    message.ack()


if __name__ == "__main__":
    print(f"Listening on {subscription_path}", flush=True)
    future = subscriber.subscribe(subscription_path, callback=callback)
    with subscriber:
        future.result()  # block forever, handling messages as they arrive
