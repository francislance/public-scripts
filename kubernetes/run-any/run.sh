#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run.sh <env> "<kubectl command>"

Examples:
  ./run.sh prod "kubectl get pods"
  ./run.sh prod "kubectl get pods -A -o wide"
  ./run.sh stg  "kubectl describe pod mypod -n myns"

Rules:
  - Command must start with: kubectl
  - Only read-only kubectl verbs allowed: get | describe
  - Output: results-<timestamp>.txt (in current dir)

Clusters file:
  ./prod_clusters.txt, ./stg_clusters.txt, ./dev_clusters.txt

Requires:
  - kubectl
  - lancelogin (used to login to each cluster)
EOF
}

ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v lancelogin     >/dev/null 2>&1 || die "lancelogin not found in PATH (replace in script if needed)"

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

# Split the quoted kubectl command safely into tokens (supports flags/args)
# shellcheck disable=SC2206
TOKENS=( ${CMD_STR} )

[[ ${#TOKENS[@]} -ge 2 ]] || die "Command must be like: \"kubectl get ...\" or \"kubectl describe ...\""

[[ "${TOKENS[0]}" == "kubectl" ]] || die "Command must start with 'kubectl'"
VERB="${TOKENS[1]}"
[[ "${VERB}" == "get" || "${VERB}" == "describe" ]] || die "Only 'kubectl get' or 'kubectl describe' allowed (got '${VERB}')"

# Remove leading "kubectl" so we can run: kubectl "${ARGS[@]}"
ARGS=( "${TOKENS[@]:1}" )

RUN_TS="$(date +'%Y%m%d-%H%M%S')"
RESULTS_FILE="${SCRIPT_DIR}/results-${RUN_TS}.txt"

# Avoid kubectl paging
export KUBECTL_PAGER=cat

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

  log "  Step: run kubectl ${ARGS[*]}"
  # Capture stdout+stderr so errors are recorded too
  if ! kubectl "${ARGS[@]}" --request-timeout=30s >> "${RESULTS_FILE}" 2>&1; then
    echo "" >> "${RESULTS_FILE}"
    echo "[WARN] kubectl command failed for cluster: ${cluster}" >> "${RESULTS_FILE}"
    log "  WARN: kubectl failed (recorded)"
  fi

  echo "" >> "${RESULTS_FILE}"
done < "${CLUSTERS_FILE}"

echo "=== RESULTS END: ${RUN_TS} ===" >> "${RESULTS_FILE}"
log "Done. Results saved to: ${RESULTS_FILE}"