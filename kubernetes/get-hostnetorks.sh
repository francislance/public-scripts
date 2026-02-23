#!/usr/bin/env bash
# scan-hostnetwork-pods.sh
# Lists all pods using spec.hostNetwork=true across multiple clusters.
# Expects an executable "login" command available in PATH:  login <cluster-name>
#
# Usage:
#   ./scan-hostnetwork-pods.sh /path/to/clusters.txt
#   ./scan-hostnetwork-pods.sh /path/to/clusters.txt /path/to/output.csv

set -euo pipefail

CLUSTERS_FILE="${1:-clusters.txt}"
OUT_FILE="${2:-hostnetwork-pods-$(date +%Y%m%d-%H%M%S).csv}"

if [[ ! -f "$CLUSTERS_FILE" ]]; then
  echo "ERROR: clusters file not found: $CLUSTERS_FILE" >&2
  exit 1
fi

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
command -v login  >/dev/null 2>&1 || { echo "ERROR: login command not found in PATH" >&2; exit 1; }

echo "cluster,context,namespace,pod,node,hostNetwork,ownerKind,ownerName" > "$OUT_FILE"

echo "Reading clusters from: $CLUSTERS_FILE"
echo "Writing report to:     $OUT_FILE"
echo

while IFS= read -r raw || [[ -n "$raw" ]]; do
  # Trim whitespace and strip comments
  cluster="$(printf '%s' "$raw" | sed 's/#.*$//' | xargs)"
  [[ -z "$cluster" ]] && continue

  echo "==> Cluster: $cluster"

  if ! login "$cluster" >/dev/null 2>&1; then
    echo "WARN: login failed for cluster: $cluster (skipping)" >&2
    continue
  fi

  context="$(kubectl config current-context 2>/dev/null || true)"
  [[ -z "$context" ]] && context="(unknown)"

  # Print to screen (nice view)
  kubectl get pods -A \
    -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,HOSTNETWORK:.spec.hostNetwork,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name \
    --no-headers \
  | awk '$4=="true"{print}' \
  | sed 's/^/  /' || true

  # Append to CSV
  kubectl get pods -A \
    -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,HOSTNETWORK:.spec.hostNetwork,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name \
    --no-headers \
  | awk -v cluster="$cluster" -v context="$context" '
      BEGIN{OFS=","}
      $4=="true"{
        # CSV-safe-ish: replace commas just in case (rare for these fields)
        for(i=1;i<=6;i++){ gsub(/,/, "_", $i) }
        print cluster,context,$1,$2,$3,$4,$5,$6
      }
    ' >> "$OUT_FILE" || true

  echo
done < "$CLUSTERS_FILE"

echo "Done."
echo "Report: $OUT_FILE"