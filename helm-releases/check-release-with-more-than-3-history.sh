#!/usr/bin/env bash

# History limit – change here or override via env:
#   HISTORY_LIMIT=5 ./check-helm.sh
HISTORY_LIMIT="${HISTORY_LIMIT:-3}"

# Temp file to accumulate "over limit" releases
TMPFILE=$(mktemp /tmp/helm-history-over-limit.XXXXXX)

# Clean up temp file on exit
trap 'rm -f "$TMPFILE"' EXIT

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
  exit 0
fi

printf "%-30s %-40s %s\n" "NAMESPACE" "RELEASE" "REVISIONS"
printf "%-30s %-40s %s\n" "---------" "-------" "---------"

# Read and print summary
while IFS='|' read -r ns rel count; do
  printf "%-30s %-40s %s\n" "$ns" "$rel" "$count"
done < "$TMPFILE"
