#!/usr/bin/env bash
# scan-hostnetwork-pods.sh
# Lists all pods using spec.hostNetwork=true across multiple clusters.
#
# Env selector:
#   ./scan-hostnetwork-pods.sh prod   -> uses prod_clusters.txt
#   ./scan-hostnetwork-pods.sh stg    -> uses stg_clusters.txt
#   ./scan-hostnetwork-pods.sh dev    -> uses dev_clusters.txt
# Or:
#   ./scan-hostnetwork-pods.sh /path/to/custom_clusters.txt
#
# Optional 2nd arg: output csv path
#   ./scan-hostnetwork-pods.sh prod /tmp/hostnetwork.csv
#
# Requires an executable "login" command in PATH: login <cluster-name>

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scan-hostnetwork-pods.sh <env|clusters_file> [output.csv]

Examples:
  ./scan-hostnetwork-pods.sh prod
  ./scan-hostnetwork-pods.sh stg /tmp/hn.csv
  ./scan-hostnetwork-pods.sh ./my_clusters.txt

Notes:
  - env can be: prod|stg|dev (maps to <env>_clusters.txt in the same dir as this script)
  - clusters file supports comments (# ...) and blank lines
EOF
}

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
command -v login  >/dev/null 2>&1 || { echo "ERROR: login command not found in PATH" >&2; exit 1; }

ARG1="${1:-}"
OUT_FILE="${2:-}"

if [[ -z "$ARG1" || "$ARG1" == "-h" || "$ARG1" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve clusters file
case "$ARG1" in
  prod|stg|dev)
    CLUSTERS_FILE="${SCRIPT_DIR}/${ARG1}_clusters.txt"
    ;;
  *)
    CLUSTERS_FILE="$ARG1"
    ;;
esac

if [[ ! -f "$CLUSTERS_FILE" ]]; then
  echo "ERROR: clusters file not found: $CLUSTERS_FILE" >&2
  exit 1
fi

if [[ -z "${OUT_FILE}" ]]; then
  base="$(basename "$CLUSTERS_FILE" .txt)"
  OUT_FILE="hostnetwork-pods-${base}-$(date +%Y%m%d-%H%M%S).csv"
fi

echo "cluster,context,namespace,pod,node,hostNetwork,ownerKind,ownerName" > "$OUT_FILE"

echo "Clusters file: $CLUSTERS_FILE"
echo "Output CSV:    $OUT_FILE"
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

  # Screen output
  kubectl get pods -A \
    -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,HOSTNETWORK:.spec.hostNetwork,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name \
    --no-headers \
  | awk '$4=="true"{print}' \
  | sed 's/^/  /' || true

  # CSV output
  kubectl get pods -A \
    -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,HOSTNETWORK:.spec.hostNetwork,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name \
    --no-headers \
  | awk -v cluster="$cluster" -v context="$context" '
      BEGIN{OFS=","}
      $4=="true"{
        for(i=1;i<=6;i++){ gsub(/,/, "_", $i) }
        print cluster,context,$1,$2,$3,$4,$5,$6
      }
    ' >> "$OUT_FILE" || true

  echo
done < "$CLUSTERS_FILE"

echo "Done. Report: $OUT_FILE"