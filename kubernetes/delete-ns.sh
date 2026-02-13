#!/usr/bin/env bash
set -euo pipefail

FILE="${1:-namespaces.txt}"

if [[ ! -f "$FILE" ]]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

while IFS= read -r ns || [[ -n "$ns" ]]; do
  # skip empty lines and comments
  [[ -z "$ns" || "$ns" =~ ^[[:space:]]*# ]] && continue

  echo "Deleting namespace: $ns"
  kubectl delete ns "$ns" --ignore-not-found
done < "$FILE"
