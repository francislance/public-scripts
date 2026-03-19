#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "60"))
ALERT_REPEAT_SECONDS = int(os.getenv("ALERT_REPEAT_SECONDS", "20"))
KUBECTL_BIN = os.getenv("KUBECTL_BIN", "kubectl")


def parse_k8s_ts(ts: str) -> datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return datetime.fromisoformat(ts)


def local_ts_string(ts: str) -> str:
    dt = parse_k8s_ts(ts)
    return dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def run_cmd(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def list_deleting_pods():
    result = run_cmd([KUBECTL_BIN, "get", "pods", "-A", "-o", "json"])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "kubectl get pods failed")

    data = json.loads(result.stdout)
    found = {}

    for item in data.get("items", []):
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "default")
        name = meta.get("name")
        deletion_ts = meta.get("deletionTimestamp")

        if not name or not deletion_ts:
            continue

        key = f"{ns}/{name}"
        found[key] = {
            "namespace": ns,
            "name": name,
            "deletion_ts": deletion_ts,
            "deletion_ts_local": local_ts_string(deletion_ts),
        }

    return found


def pod_still_deleting(namespace: str, name: str):
    result = run_cmd([KUBECTL_BIN, "get", "pod", name, "-n", namespace, "-o", "json"])
    if result.returncode != 0:
        return False, None

    data = json.loads(result.stdout)
    deletion_ts = data.get("metadata", {}).get("deletionTimestamp")
    if deletion_ts:
        return True, deletion_ts
    return False, None


def play_alert(message: str):
    subprocess.run(
        ["/usr/bin/osascript", "-e", "beep 3"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", f'display notification "{message}" with title "Kubernetes Alert"'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.Popen(
        ["/usr/bin/say", message],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main():
    tracked = {}
    last_alert = {}

    print("Monitoring pods that remain deleting after the check interval...")
    print(f"Check interval      : {CHECK_INTERVAL}s")
    print(f"Repeat alert        : {ALERT_REPEAT_SECONDS}s")
    print(f"Kubectl             : {KUBECTL_BIN}")
    print()

    while True:
        try:
            now = time.time()
            current = list_deleting_pods()

            # Track newly found deleting pods
            for key, info in current.items():
                if key not in tracked:
                    tracked[key] = {
                        "namespace": info["namespace"],
                        "name": info["name"],
                        "deletion_ts": info["deletion_ts"],
                        "deletion_ts_local": info["deletion_ts_local"],
                        "first_seen_epoch": now,
                    }
                    print(f"Tracking {key} delete time {info['deletion_ts_local']}")

            # Re-check tracked pods after CHECK_INTERVAL
            to_remove = []

            for key, info in tracked.items():
                if now - info["first_seen_epoch"] < CHECK_INTERVAL:
                    continue

                still_deleting, current_delete_ts = pod_still_deleting(info["namespace"], info["name"])

                if not still_deleting:
                    to_remove.append(key)
                    continue

                # Repeat alert while it stays deleting
                prev = last_alert.get(key, 0)
                if now - prev >= ALERT_REPEAT_SECONDS:
                    msg = (
                        f"Pod still terminating. {key}. "
                        f"Delete requested at {info['deletion_ts_local']}."
                    )
                    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ALERT: {msg}")
                    play_alert(msg)
                    last_alert[key] = now

            for key in to_remove:
                tracked.pop(key, None)
                last_alert.pop(key, None)

        except KeyboardInterrupt:
            print("\nStopped.")
            return 0
        except Exception as e:
            print(f"ERROR: {e}", file=sys.stderr)

        time.sleep(1)


if __name__ == "__main__":
    raise SystemExit(main())