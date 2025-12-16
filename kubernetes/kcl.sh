#!/usr/bin/env bash
set -euo pipefail

# =========================
# ABSOLUTE PATH DECLARATIONS
# =========================
KCL_HOME="/opt/kcl"
CSV_FILE="${KCL_HOME}/clusters.csv"
PASS_B64_FILE="${KCL_HOME}/password.b64"
PATTERN_FILE="${KCL_HOME}/login.pattern"
# =========================

CLUSTER="${1:-}"

usage() {
  echo "Usage: kcl <clustername>"
  echo "Debug: KCL_DEBUG=1 kcl <clustername>"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

get_row_for_cluster() {
  awk -F',' -v c="$1" '
    NR==1 { next }
    $1==c { print; found=1; exit }
    END { if (!found) exit 2 }
  ' "$CSV_FILE"
}

decode_password() {
  local b64
  b64="$(head -n 1 "$PASS_B64_FILE" | tr -d '\r\n' | trim)"

  if base64 --help 2>/dev/null | grep -q -- '-d'; then
    printf '%s' "$b64" | base64 -d | tr -d '\r\n'
  else
    printf '%s' "$b64" | base64 -D | tr -d '\r\n'
  fi
}

load_pattern() {
  grep -v '^[[:space:]]*$' "$PATTERN_FILE" \
    | grep -v '^[[:space:]]*#' \
    | head -n 1
}

apply_pattern() {
  local pat="$1"
  pat="${pat//\{clustername\}/$2}"
  pat="${pat//\{kubernetes-api-url\}/$3}"
  pat="${pat//\{username\}/$4}"
  pat="${pat//\{auth-api-url\}/$5}"
  echo "$pat"
}

main() {
  [[ -n "$CLUSTER" ]] || { usage; exit 1; }

  need expect
  need base64
  need awk

  row="$(get_row_for_cluster "$CLUSTER")" || {
    echo "ERROR: cluster not found: $CLUSTER" >&2
    exit 1
  }

  IFS=',' read -r clustername k8s_url username auth_url <<<"$row"

  password="$(decode_password)"
  pattern="$(load_pattern)"
  cmd="$(apply_pattern "$pattern" "$clustername" "$k8s_url" "$username" "$auth_url")"

  export KCL_CMD="$cmd"
  export KCL_PASSWORD="$password"
  export KCL_DEBUG="${KCL_DEBUG:-0}"

  expect <<'EOF'
set timeout -1

if {$env(KCL_DEBUG) == "1"} {
  exp_internal 1
}

log_user 1
spawn sh -lc $env(KCL_CMD)

set sent 0
expect {
  -re "(?i)(password|passcode|pin)[^\r\n]*[:? ]*$" {
    if {$sent == 0} {
      send -- "$env(KCL_PASSWORD)\r"
      set sent 1
    }
    exp_continue
  }
  -re "(?i)(enter|type)[^\r\n]*(password|passcode|pin)[^\r\n]*$" {
    if {$sent == 0} {
      send -- "$env(KCL_PASSWORD)\r"
      set sent 1
    }
    exp_continue
  }
  eof
}
EOF
}

main "$@"
