#!/usr/bin/env bash
# scan-hostnetwork-pods.sh
# Multi-cluster scan for pods using spec.hostNetwork=true.
# - Shows every step on screen
# - Writes the same logs to a timestamped logfile (with timestamps per line)
# - Writes a timestamped CSV report
#
# Usage:
#   ./scan-hostnetwork-pods.sh prod
#   ./scan-hostnetwork-pods.sh stg /path/to/outdir
#   ./scan-hostnetwork-pods.sh dev /path/to/outdir
#   ./scan-hostnetwork-pods.sh /path/to/custom_clusters.txt /path/to/outdir
#
# Requirements:
#   - kubectl
#   - login <cluster-name> command in PATH (sets kube context)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scan-hostnetwork-pods.sh <env|clusters_file> [out_dir]

Where:
  <env> can be: prod|stg|dev  (uses <script_dir>/<env>_clusters.txt)
  or provide a clusters file path directly.

Outputs (in out_dir, default: current dir):
  - hostnetwork-pods-<envOrFileBase>-YYYYmmdd-HHMMSS.csv
  - scan-hostnetwork-<envOrFileBase>-YYYYmmdd-HHMMSS.log
EOF
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  # Print with timestamp to stdout (which is tee'd to logfile)
  echo "[$(ts)] $*"
}

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
command -v login  >/dev/null 2>&1 || { echo "ERROR: login command not found in PATH" >&2; exit 1; }

ARG1="${1:-}"
OUT_DIR="${2:-.}"

if [[ -z "$ARG1" || "$ARG1" == "-h" || "$ARG1" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# Resolve clusters file
case "$ARG1" in
  prod|stg|dev)
    CLUSTERS_FILE="${SCRIPT_DIR}/${ARG1}_clusters.txt"
    BASE_ID="$ARG1"
    ;;
  *)
    CLUSTERS_FILE="$ARG1"
    BASE_ID="$(basename "$CLUSTERS_FILE")"
    BASE_ID="${BASE_ID%.*}"   # strip extension
    ;;
esac

if [[ ! -f "$CLUSTERS_FILE" ]]; then
  echo "ERROR: clusters file not found: $CLUSTERS_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

CSV_FILE="${OUT_DIR}/hostnetwork-pods-${BASE_ID}-${RUN_TS}.csv"
LOG_FILE="${OUT_DIR}/scan-hostnetwork-${BASE_ID}-${RUN_TS}.log"

# Send ALL stdout+stderr to screen and logfile (raw), while we also prefix our own messages with timestamps.
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting hostNetwork scan"
log "Clusters file : $CLUSTERS_FILE"
log "Output CSV    : $CSV_FILE"
log "Log file      : $LOG_FILE"
log "Out dir       : $OUT_DIR"
log "--------------------------------------------------------------------------------"

# CSV header
echo "cluster,context,namespace,pod,node,hostNetwork,ownerKind,ownerName" > "$CSV_FILE"

# Read clusters
while IFS= read -r raw || [[ -n "$raw" ]]; do
  # Trim whitespace and strip comments
  cluster="$(printf '%s' "$raw" | sed 's/#.*$//' | xargs)"
  [[ -z "$cluster" ]] && continue

  log "Cluster: $cluster"
  log "Step: login \"$cluster\""
  if ! login "$cluster"; then
    log "WARN: login failed for cluster: $cluster (skipping)"
    log "--------------------------------------------------------------------------------"
    continue
  fi

  log "Step: kubectl config current-context"
  context="$(kubectl config current-context 2>/dev/null || true)"
  [[ -z "$context" ]] && context="(unknown)"
  log "Current context: $context"

  log "Step: query pods across all namespaces and filter hostNetwork=true"

  # Print matching pods to screen (if any)
  matches="$(
    kubectl get pods -A \
      -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,HOSTNETWORK:.spec.hostNetwork,OWNER_KIND:.metadata.ownerReferences[0].kind,OWNER_NAME:.metadata.ownerReferences[0].name \
      --no-headers \
    | awk '$4=="true"{print}'
  )" || matches=""

  if [[ -z "$matches" ]]; then
    log "Result: no hostNetwork pods found in this cluster."
  else
    log "Result: found hostNetwork pods:"
    # indent for readability
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "[$(ts)]   $line"
    done <<< "$matches"

    log "Step: append results to CSV"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # line format: NS POD NODE HOSTNETWORK OWNER_KIND OWNER_NAME (space-separated)
      ns="$(awk '{print $1}' <<< "$line")"
      pod="$(awk '{print $2}' <<< "$line")"
      node="$(awk '{print $3}' <<< "$line")"
      hostnet="$(awk '{print $4}' <<< "$line")"
      okind="$(awk '{print $5}' <<< "$line")"
      oname="$(awk '{print $6}' <<< "$line")"

      # Basic CSV safety: replace commas if ever present
      ns="${ns//,/ _}"; pod="${pod//,/ _}"; node="${node//,/ _}"
      hostnet="${hostnet//,/ _}"; okind="${okind//,/ _}"; oname="${oname//,/ _}"
      c="${cluster//,/ _}"; ctx="${context//,/ _}"

      echo "${c},${ctx},${ns},${pod},${node},${hostnet},${okind},${oname}" >> "$CSV_FILE"
    done <<< "$matches"
  fi

  log "--------------------------------------------------------------------------------"
done < "$CLUSTERS_FILE"

log "Completed."
log "CSV report: $CSV_FILE"
log "Log file  : $LOG_FILE"