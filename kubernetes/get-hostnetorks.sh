#!/usr/bin/env bash
# scan-hostnetwork-pods.sh
# Multi-cluster scan for pods using spec.hostNetwork=true.
# - Shows every step on screen
# - Writes the same logs to a timestamped logfile (with timestamps per line)
# - Writes a timestamped CSV report
#
# Usage:
#   ./scan-hostnetwork-pods.sh prod
#   ./scan-hostnetwork-pods.sh prod --limit-cluster={cluster1,cluster2}
#   ./scan-hostnetwork-pods.sh prod /tmp/reports --limit-cluster=cluster1,cluster2
#   ./scan-hostnetwork-pods.sh stg --out-dir=/tmp/reports --limit-cluster=cluster1
#   ./scan-hostnetwork-pods.sh /path/to/custom_clusters.txt --limit-cluster=clusterA,clusterB
#
# Requirements:
#   - kubectl
#   - login <cluster-name> command in PATH (sets kube context)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scan-hostnetwork-pods.sh <env|clusters_file> [out_dir] [--limit-cluster=...] [--out-dir=...]

Examples:
  ./scan-hostnetwork-pods.sh prod
  ./scan-hostnetwork-pods.sh prod --limit-cluster={cluster1,cluster2}
  ./scan-hostnetwork-pods.sh stg /tmp/reports --limit-cluster=cluster1,cluster2
  ./scan-hostnetwork-pods.sh dev --out-dir=/tmp/reports

Options:
  --limit-cluster=cluster1,cluster2
    Limits scanning to ONLY those clusters (names must match the lines in the clusters file).
    Braces are optional: {cluster1,cluster2} or cluster1,cluster2

  --out-dir=/path
    Output directory for CSV + log. (Alternative to positional out_dir)

Notes:
  - env can be: prod|stg|dev (maps to <script_dir>/<env>_clusters.txt)
  - clusters file supports comments (# ...) and blank lines
EOF
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*"; }

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found in PATH" >&2; exit 1; }
command -v login  >/dev/null 2>&1 || { echo "ERROR: login command not found in PATH" >&2; exit 1; }

ARG1="${1:-}"
shift || true

if [[ -z "${ARG1}" || "${ARG1}" == "-h" || "${ARG1}" == "--help" ]]; then
  usage
  exit 0
fi

OUT_DIR="."
LIMIT_RAW=""

# Parse remaining args (supports positional out_dir + flags)
while (($#)); do
  case "$1" in
    --limit-cluster=*)
      LIMIT_RAW="${1#*=}"
      shift
      ;;
    --limit-cluster)
      LIMIT_RAW="${2:-}"
      shift 2
      ;;
    --out-dir=*)
      OUT_DIR="${1#*=}"
      shift
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    *)
      # treat first unknown positional as out_dir (backwards compatible)
      if [[ "$OUT_DIR" == "." ]]; then
        OUT_DIR="$1"
        shift
      else
        echo "ERROR: Unknown argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

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
    BASE_ID="${BASE_ID%.*}"
    ;;
esac

if [[ ! -f "$CLUSTERS_FILE" ]]; then
  echo "ERROR: clusters file not found: $CLUSTERS_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

CSV_FILE="${OUT_DIR}/hostnetwork-pods-${BASE_ID}-${RUN_TS}.csv"
LOG_FILE="${OUT_DIR}/scan-hostnetwork-${BASE_ID}-${RUN_TS}.log"

# Send ALL stdout+stderr to screen and logfile
exec > >(tee -a "$LOG_FILE") 2>&1

# Build limit set (optional)
declare -A LIMIT_SET=()
LIMIT_ENABLED="false"

if [[ -n "$LIMIT_RAW" ]]; then
  # Accept "{a,b}" or "a,b" and ignore spaces
  cleaned="$(printf '%s' "$LIMIT_RAW" | tr -d '{}' | tr -d '[:space:]')"
  IFS=',' read -r -a LIMIT_ARR <<< "$cleaned"
  for c in "${LIMIT_ARR[@]}"; do
    [[ -n "$c" ]] && LIMIT_SET["$c"]=1
  done
  if ((${#LIMIT_SET[@]} > 0)); then
    LIMIT_ENABLED="true"
  fi
fi

log "Starting hostNetwork scan"
log "Clusters file : $CLUSTERS_FILE"
log "Output CSV    : $CSV_FILE"
log "Log file      : $LOG_FILE"
log "Out dir       : $OUT_DIR"
if [[ "$LIMIT_ENABLED" == "true" ]]; then
  log "Limit clusters: ${!LIMIT_SET[*]}"
else
  log "Limit clusters: (none)"
fi
log "--------------------------------------------------------------------------------"

# CSV header
echo "cluster,context,namespace,pod,node,hostNetwork,ownerKind,ownerName" > "$CSV_FILE"

# Read clusters
while IFS= read -r raw || [[ -n "$raw" ]]; do
  cluster="$(printf '%s' "$raw" | sed 's/#.*$//' | xargs)"
  [[ -z "$cluster" ]] && continue

  if [[ "$LIMIT_ENABLED" == "true" && -z "${LIMIT_SET[$cluster]+x}" ]]; then
    log "Skipping cluster (not in --limit-cluster): $cluster"
    continue
  fi

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
  log "kubectl command: kubectl get pods -A -o custom-columns=... --no-headers"

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
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "[$(ts)]   $line"
    done <<< "$matches"

    log "Step: append results to CSV"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      ns="$(awk '{print $1}' <<< "$line")"
      pod="$(awk '{print $2}' <<< "$line")"
      node="$(awk '{print $3}' <<< "$line")"
      hostnet="$(awk '{print $4}' <<< "$line")"
      okind="$(awk '{print $5}' <<< "$line")"
      oname="$(awk '{print $6}' <<< "$line")"

      # basic CSV safety
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