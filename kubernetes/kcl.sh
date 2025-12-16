#!/usr/bin/env bash
set -euo pipefail

# =========================
# ABSOLUTE PATH DECLARATIONS
# =========================
KCL_HOME="/opt/kcl"                       # <- change if you want
CSV_FILE="${KCL_HOME}/clusters.csv"
PASS_B64_FILE="${KCL_HOME}/password.b64"
PATTERN_FILE="${KCL_HOME}/login.pattern"
# =========================

CLUSTER="${1:-}"

usage() {
  echo "Usage: kcl <clustername>"
  echo
  echo "Using files:"
  echo "  CSV     : $CSV_FILE"
  echo "  PASS    : $PASS_B64_FILE"
  echo "  PATTERN : $PATTERN_FILE"
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

get_row_for_cluster() {
  local cluster="$1"
  [[ -f "$CSV_FILE" ]] || { echo "ERROR: CSV not found: $CSV_FILE" >&2; exit 1; }

  awk -F',' -v c="$cluster" '
    NR==1 { next }
    $1==c { print; found=1; exit }
    END { if (!found) exit 2 }
  ' "$CSV_FILE"
}

decode_password() {
  [[ -f "$PASS_B64_FILE" ]] || { echo "ERROR: password file not found: $PASS_B64_FILE" >&2; exit 1; }
  local b64
  b64="$(head -n 1 "$PASS_B64_FILE" | tr -d '\r\n' | trim)"
  [[ -n "$b64" ]] || { echo "ERROR: password file is empty: $PASS_B64_FILE" >&2; exit 1; }

  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    printf '%s' "$b64" | base64 -d
  else
    printf '%s' "$b64" | base64 -D
  fi
}

load_pattern() {
  [[ -f "$PATTERN_FILE" ]] || { echo "ERROR: pattern file not found: $PATTERN_FILE" >&2; exit 1; }
  local pat
  pat="$(grep -v '^[[:space:]]*$' "$PATTERN_FILE" | grep -v '^[[:space:]]*#' | head -n 1 || true)"
  pat="$(printf '%s' "$pat" | trim)"
  [[ -n "$pat" ]] || { echo "ERROR: pattern file has no usable line: $PATTERN_FILE" >&2; exit 1; }
  printf '%s' "$pat"
}

apply_pattern() {
  local pat="$1" clustername="$2" k8s_url="$3" username="$4" auth_url="$5"
  pat="${pat//\{clustername\}/$clustername}"
  pat="${pat//\{kubernetes-api-url\}/$k8s_url}"
  pat="${pat//\{username\}/$username}"
  pat="${pat//\{auth-api-url\}/$auth_url}"
  printf '%s' "$pat"
}

main() {
  [[ -n "$CLUSTER" ]] || { usage; exit 1; }

  need awk
  need base64
  need expect

  local row
  if ! row="$(get_row_for_cluster "$CLUSTER")"; then
    rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "ERROR: clustername not found in CSV: $CLUSTER" >&2
    else
      echo "ERROR: failed reading CSV." >&2
    fi
    exit 1
  fi

  local clustername k8s_url username auth_url
  IFS=',' read -r clustername k8s_url username auth_url <<<"$row"

  clustername="$(printf '%s' "$clustername" | trim)"
  k8s_url="$(printf '%s' "$k8s_url" | trim)"
  username="$(printf '%s' "$username" | trim)"
  auth_url="$(printf '%s' "$auth_url" | trim)"

  [[ -n "$k8s_url" && -n "$username" && -n "$auth_url" ]] || {
    echo "ERROR: CSV row missing fields for '$CLUSTER': $row" >&2
    exit 1
  }

  local password pattern cmd
  password="$(decode_password)"
  pattern="$(load_pattern)"
  cmd="$(apply_pattern "$pattern" "$clustername" "$k8s_url" "$username" "$auth_url")"

  expect <<EOF
set timeout -1
log_user 1
spawn sh -lc "$cmd"
expect {
  -re "(?i)password.*: *$" {
    send -- "$password\r"
    exp_continue
  }
  eof
}
EOF
}

main "$@"
