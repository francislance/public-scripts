#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# run.sh
#
# Runs a READ-ONLY kubectl command across all clusters listed in
# <env>_clusters.txt and writes output to results-<timestamp>.txt
# with per-cluster sections.
#
# CLI (exactly as you want):
#   ./run.sh prod "kubectl get pods"
#   ./run.sh stg  "kubectl describe pod mypod -n myns"
#   ./run.sh stg  "kubectl get tnt | grep -i wrb"
#
# Enforced rule:
#   - Command (after optional leading spaces) MUST start with:
#       kubectl get ...
#       kubectl describe ...
#
# Notes:
#   - Pipes/grep/etc work because we execute via: bash -lc "<command>"
#   - Captures stdout+stderr to results file.
#   - Uses `lancelogin <cluster>` to login per cluster (adjust if needed).
# ------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  ./run.sh <env> "<kubectl command>"

Where:
  <env> must be: prod | stg | dev
  "<kubectl command>" must start with: kubectl get ...  OR  kubectl describe ...

Examples:
  ./run.sh prod "kubectl get pods"
  ./run.sh prod "kubectl get pods -A -o wide"
  ./run.sh stg  "kubectl describe pod mypod -n myns"
  ./run.sh stg  "kubectl get tnt | grep -i wrb"
  ./run.sh dev  "kubectl get nodes | grep -i ready"

Clusters file:
  ./prod_clusters.txt, ./stg_clusters.txt, ./dev_clusters.txt
  (Supports blank lines and comments starting with '#')

Output:
  ./results-<timestamp>.txt

Requires:
  - kubectl
  - lancelogin (per-cluster login)
EOF
}

ts()  { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v lancelogin     >/dev/null 2>&1 || die "lancelogin not found in PATH (replace in script if needed)"
command -v bash    >/dev/null 2>&1 || die "bash not found (unexpected on macOS)"

ENV_ARG="${1:-}"
CMD_STR="${2:-}"

if [[ -z "${ENV_ARG}" || -z "${CMD_STR}" || "${ENV_ARG}" == "-h" || "${ENV_ARG}" == "--help" ]]; then
  usage
  exit 0
fi

case "${ENV_ARG}" in
  prod|stg|dev) ;;
  *) die "Invalid env '${ENV_ARG}'. Must be prod|stg|dev." ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERS_FILE="${SCRIPT_DIR}/${ENV_ARG}_clusters.txt"
[[ -f "${CLUSTERS_FILE}" ]] || die "Clusters file not found: ${CLUSTERS_FILE}"

# Avoid kubectl paging
export KUBECTL_PAGER=cat

# -----------------------------
# Validate command is read-only
# -----------------------------
# Trim leading spaces
trimmed="${CMD_STR#"${CMD_STR%%[![:space:]]*}"}"

# Must start with: kubectl get ... OR kubectl describe ...
if [[ ! "${trimmed}" =~ ^kubectl[[:space:]]+(get|describe)([[:space:]]|$) ]]; then
  die "Command must start with 'kubectl get' or 'kubectl describe'. Got: ${CMD_STR}"
fi

# (Optional but recommended) block obvious shell-chaining / output redirection
# so users can't do: "kubectl get pods; rm -rf /" or redirect secrets to files.
# If you WANT to allow these, comment out this block.
if echo "${CMD_STR}" | grep -Eq '[;&]|\|\||&&|`|\$\(|\)|(^|[[:space:]])>(>|&)?|(^|[[:space:]])<(<?)?'; then
  die "Unsafe shell operators detected. Allowed: pipes '|' only (plus normal args)."
fi

# Also block dangerous kubectl verbs if someone tries to sneak them in.
# (Even though we require the command starts with get/describe, keep this anyway.)
if echo "${CMD_STR}" | grep -Eq '(^|[[:space:]])kubectl[[:space:]]+(apply|delete|edit|patch|replace|create|run|exec|cp|attach|scale|rollout|set|label|annotate|autoscale|drain|cordon|uncordon|taint)([[:space:]]|$)'; then
  die "Blocked kubectl verb detected. Only 'get' or 'describe' allowed."
fi

RUN_TS="$(date +'%Y%m%d-%H%M%S')"
RESULTS_FILE="${SCRIPT_DIR}/results-${RUN_TS}.txt"

log "Starting run"
log "Env          : ${ENV_ARG}"
log "Clusters file: ${CLUSTERS_FILE}"
log "Command      : ${CMD_STR}"
log "Results file : ${RESULTS_FILE}"

{
  echo "=== RESULTS START: ${RUN_TS} ==="
  echo "Env: ${ENV_ARG}"
  echo "Command: ${CMD_STR}"
  echo "Clusters file: ${CLUSTERS_FILE}"
  echo ""
} > "${RESULTS_FILE}"

# Read clusters (supports blank lines and comments starting with #)
while IFS= read -r raw || [[ -n "${raw}" ]]; do
  line="$(echo "${raw}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^# ]] && continue

  cluster="${line}"

  {
    echo "============================================================"
    echo "CLUSTER: ${cluster}"
    echo "TIME   : $(ts)"
    echo "============================================================"
  } >> "${RESULTS_FILE}"

  log "Cluster: ${cluster}"
  log "  Step: lancelogin login"
  if ! lancelogin "${cluster}" >/dev/null 2>&1; then
    echo "[WARN] lancelogin login failed for cluster: ${cluster}" >> "${RESULTS_FILE}"
    echo "" >> "${RESULTS_FILE}"
    log "  WARN: lancelogin login failed (skipping)"
    continue
  fi

  ctx="$(kubectl config current-context 2>/dev/null || true)"
  [[ -n "${ctx}" ]] || ctx="(unknown)"
  echo "Current context: ${ctx}" >> "${RESULTS_FILE}"
  echo "" >> "${RESULTS_FILE}"

  # Add request timeout unless user already provided one
  CMD_TO_RUN="${CMD_STR}"
  if [[ "${CMD_STR}" != *"--request-timeout"* ]]; then
    CMD_TO_RUN="${CMD_STR} --request-timeout=30s"
  fi

  log "  Step: run ${CMD_TO_RUN}"

  # Run via bash so pipes/grep work; capture stdout+stderr
  if ! bash -lc "${CMD_TO_RUN}" >> "${RESULTS_FILE}" 2>&1; then
    echo "" >> "${RESULTS_FILE}"
    echo "[WARN] command failed for cluster: ${cluster}" >> "${RESULTS_FILE}"
    log "  WARN: command failed (recorded)"
  fi

  echo "" >> "${RESULTS_FILE}"
done < "${CLUSTERS_FILE}"

echo "=== RESULTS END: ${RUN_TS} ===" >> "${RESULTS_FILE}"
log "Done. Results saved to: ${RESULTS_FILE}"