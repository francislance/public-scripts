#!/usr/bin/env bash

set -u

# ---------------- Config & CLI parsing ----------------

DEFAULT_HISTORY_LIMIT=3

# Base value (can be overridden by env, then by CLI)
HISTORY_LIMIT="${HISTORY_LIMIT:-$DEFAULT_HISTORY_LIMIT}"

SUMMARY_FILE="helm-releases-summary.txt"
DETAILS_FILE="helm-releases-details.txt"

# Parse CLI args
for arg in "$@"; do
  case "$arg" in
    --history-limit=*)
      HISTORY_LIMIT="${arg#*=}"
      ;;
    -h|--help)
      echo "Usage: $0 [--history-limit=N]"
      echo
      echo "Options:"
      echo "  --history-limit=N   Number of revisions allowed per release (default: ${DEFAULT_HISTORY_LIMIT})."
      echo "                      Precedence: CLI > \$HISTORY_LIMIT env > default."
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo "Use --help for usage." >&2
      exit 1
      ;;
  esac
done

# Validate HISTORY_LIMIT is a positive integer
if ! [[ "$HISTORY_LIMIT" =~ ^[0-9]+$ ]] || [ "$HISTORY_LIMIT" -le 0 ]; then
  echo "ERROR: HISTORY_LIMIT must be a positive integer (got: '$HISTORY_LIMIT')." >&2
  exit 1
fi

# ---------------- Setup & checks ----------------

# Temp file to accumulate "over limit" releases
TMPFILE=$(mktemp /tmp/helm-history-over-limit.XXXXXX)

# Clean up temp file on exit
trap 'rm -f "$TMPFILE"' EXIT

# Basic checks
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm not found in PATH" >&2
  exit 1
fi

# Init / truncate output files
: > "${SUMMARY_FILE}"
: > "${DETAILS_FILE}"

# Write headers to files
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

# ---------------- Main logic ----------------

# Get all namespaces
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

    # Get history; if it fails, warn and continue
    if ! history_output=$(helm history "$rel" -n "$ns" 2>/dev/null); then
      echo "[WARN] Failed to get history for $rel in $ns"
      echo

      {
        echo "=================================================="
        echo "Namespace: $ns"
        echo "Release: $rel"
        echo "[WARN] Failed to get history for $rel in $ns"
        echo
      } >> "${DETAILS_FILE}"

      continue
    fi

    echo "$history_output"
    echo

    # Count revisions (skip header line)
    revision_count=$(
      printf '%s\n' "$history_output" \
        | tail -n +2 \
        | wc -l \
        | awk '{print $1}'
    )

    echo "Revision count: $revision_count"
    echo

    # Append to details file
    {
      echo "=================================================="
      echo "Namespace: $ns"
      echo "Release: $rel"
      echo "--------------------------------------------------"
      echo "$history_output"
      echo
      echo "Revision count: $revision_count"
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

  # Also reflect this in the summary file
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
