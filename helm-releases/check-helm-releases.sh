#!/usr/bin/env bash

# Scan all namespaces and Helm releases, record history counts,
# and produce:
#   - helm-releases-summary.txt
#   - helm-releases-details.txt
#
# Usage:
#   ./check-helm.sh [--history-limit=N]
#
# History limit precedence:
#   1. --history-limit=N
#   2. HISTORY_LIMIT env var
#   3. default = 3
#
# Requirements:
#   - bash
#   - kubectl
#   - helm
#   - jq

set -u

HISTORY_LIMIT="${HISTORY_LIMIT:-3}"
SUMMARY_FILE="helm-releases-summary.txt"
DETAILS_FILE="helm-releases-details.txt"

# ---------- Parse arguments ----------
for arg in "$@"; do
  case "$arg" in
    --history-limit=*)
      HISTORY_LIMIT="${arg#*=}"
      ;;
    -h|--help)
      echo "Usage: $0 [--history-limit=N]"
      echo
      echo "  --history-limit=N   Desired max history per release (default: 3)"
      echo "                      Also can be set via HISTORY_LIMIT env var."
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# Validate HISTORY_LIMIT
if ! [[ "${HISTORY_LIMIT}" =~ ^[0-9]+$ ]] || [ "${HISTORY_LIMIT}" -le 0 ]; then
  echo "ERROR: HISTORY_LIMIT must be a positive integer, got: '${HISTORY_LIMIT}'" >&2
  exit 1
fi

# Temp file to accumulate "over limit" releases
TMPFILE=$(mktemp /tmp/helm-history-over-limit.XXXXXX)

# Clean up temp file on exit
trap 'rm -f "$TMPFILE"' EXIT

# ---------- Basic checks ----------
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm not found in PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH" >&2
  exit 1
fi

# ---------- Init / truncate output files ----------
: > "${SUMMARY_FILE}"
: > "${DETAILS_FILE}"

# Headers
{
  echo "SUMMARY: Releases with more than ${HISTORY_LIMIT} revisions"
  echo "Report generated through script - check-helm.sh"
  echo "Generated at: $(date -Iseconds)"
  echo "History limit: ${HISTORY_LIMIT}"
  echo "=================================================="
} >> "${SUMMARY_FILE}"

{
  echo "DETAILS: Helm release histories"
  echo "Report generated through script - check-helm.sh"
  echo "Generated at: $(date -Iseconds)"
  echo "History limit: ${HISTORY_LIMIT}"
  echo "=================================================="
  echo
} >> "${DETAILS_FILE}"

# ---------- Get all namespaces ----------
namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

for ns in $namespaces; do
  echo "=================================================="
  echo "Namespace: $ns"
  echo "=================================================="

  # Get releases in this namespace (names only)
  releases=$(helm list -n "$ns" -q 2>/dev/null || true)

  if [ -z "$releases" ]; then
    echo "No helm releases in namespace: $ns"
    echo
    continue
  fi

  for rel in $releases; do
    echo "--------------------------------------------------"
    echo "Release: $rel (namespace: $ns)"
    echo "--------------------------------------------------"

    # Get history (JSON) for counting
    history_json=$(helm history "$rel" -n "$ns" -o json 2>/dev/null || true)
    if [ -z "$history_json" ] || [ "$history_json" = "null" ]; then
      echo "[WARN] Failed to get JSON history for $rel in $ns"
      echo

      {
        echo "=================================================="
        echo "Namespace: $ns"
        echo "Release: $rel"
        echo "[WARN] Failed to get JSON history for $rel in $ns"
        echo
      } >> "${DETAILS_FILE}"

      continue
    fi

    # Count revisions from JSON (robust)
    revision_count=$(echo "${history_json}" | jq 'length')

    echo "Revision count (from JSON): $revision_count"
    echo

    # Also get table output for human-readable details file
    history_table=$(helm history "$rel" -n "$ns" 2>/dev/null || true)

    {
      echo "=================================================="
      echo "Namespace: $ns"
      echo "Release: $rel"
      echo "--------------------------------------------------"
      if [ -n "$history_table" ]; then
        echo "$history_table"
        echo
      else
        echo "[WARN] Failed to get text history for $rel in $ns"
        echo
      fi
      echo "Revision count (from JSON): $revision_count"
      echo
    } >> "${DETAILS_FILE}"

    # Store any release above the limit into the temp file
    if [ "$revision_count" -gt "$HISTORY_LIMIT" ]; then
      # use | as separator; safe for most names
      printf '%s|%s|%s\n' "$ns" "$rel" "$revision_count" >> "$TMPFILE"
    fi
  done

  echo
done

echo "=================================================="
echo "SUMMARY: Releases with more than $HISTORY_LIMIT revisions"
echo "=================================================="

if [ ! -s "$TMPFILE" ]; then
  echo "None 🎉"

  {
    echo "None 🎉"
  } >> "${SUMMARY_FILE}"

  echo
  echo "Summary written to:   ${SUMMARY_FILE}"
  echo "Details written to:   ${DETAILS_FILE}"
  exit 0
fi

# Print table header to screen
printf "%-30s %-40s %s\n" "NAMESPACE" "RELEASE" "REVISIONS"
printf "%-30s %-40s %s\n" "---------" "-------" "---------"

# Print table header to summary file
{
  printf "%-30s %-40s %s\n" "NAMESPACE" "RELEASE" "REVISIONS"
  printf "%-30s %-40s %s\n" "---------" "-------" "---------"
} >> "${SUMMARY_FILE}"

# Read and print summary, and also append to summary file
while IFS='|' read -r ns rel count; do
  printf "%-30s %-40s %s\n" "$ns" "$rel" "$count"
  printf "%-30s %-40s %s\n" "$ns" "$rel" "$count" >> "${SUMMARY_FILE}"
done < "$TMPFILE"

echo
echo "Summary written to:   ${SUMMARY_FILE}"
echo "Details written to:   ${DETAILS_FILE}"
