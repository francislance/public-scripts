#!/usr/bin/env bash
set -euo pipefail

# =========================
# ABSOLUTE PATH DECLARATIONS
# =========================
: "${KCL_HOME:=/media/sf_2032658/Documents/Configs/kcl}"
CSV_FILE="${KCL_HOME}/clusters.csv"
PASS_B64_FILE="${KCL_HOME}/password.b64"
PATTERN_FILE="${KCL_HOME}/login.pattern"
# =========================

# Default: 90 seconds. Override: KCL_TIMEOUT=30 kcl dev
KCL_TIMEOUT="${KCL_TIMEOUT:-90}"

CLUSTER="${1:-}"
KCL_DEBUG="${KCL_DEBUG:-0}"

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
need() { command -v "$1" >/dev/null 2>&1 || exit 127; }

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
    | head -n 1 \
    | tr -d '\r' \
    | trim
}

# Pattern supports:
#  - {kubernetes-api-url}
#  - {username}
#  - {auth-flag}   -> becomes "-s <auth-url>" or "" if missing
#  - {clustername} -> optional
apply_pattern() {
  local pat="$1"
  local clustername="$2"
  local k8s_url="$3"
  local username="$4"
  local auth_url="${5:-}"

  local auth_flag=""
  if [[ -n "$auth_url" ]]; then
    auth_flag="-s $auth_url"
  fi

  pat="${pat//\{clustername\}/$clustername}"
  pat="${pat//\{kubernetes-api-url\}/$k8s_url}"
  pat="${pat//\{username\}/$username}"
  pat="${pat//\{auth-flag\}/$auth_flag}"

  printf '%s' "$pat" | tr -s ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

spinner_start() {
  (
    local dots=1
    while true; do
      printf '\rLogging in%.*s   ' "$dots" "..."
      dots=$((dots + 1))
      [[ $dots -gt 3 ]] && dots=1
      sleep 1
    done
  ) &
  echo $!
}

spinner_stop_with_message() {
  local pid="$1"
  local msg="$2"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  printf '\r%s\n' "$msg"
}

main() {
  need expect
  need awk
  need base64

  [[ -n "$CLUSTER" ]] || { echo "Login failed."; exit 1; }
  [[ -f "$CSV_FILE" && -f "$PASS_B64_FILE" && -f "$PATTERN_FILE" ]] || {
    [[ "$KCL_DEBUG" == "1" ]] && echo "DEBUG: missing files under KCL_HOME=$KCL_HOME"
    echo "Login failed."
    exit 1
  }

  local row
  if ! row="$(get_row_for_cluster "$CLUSTER" 2>/dev/null)"; then
    echo "Login failed."
    exit 1
  fi

  local clustername k8s_url username auth_url
  IFS=',' read -r clustername k8s_url username auth_url <<<"$row"
  clustername="$(printf '%s' "$clustername" | trim)"
  k8s_url="$(printf '%s' "$k8s_url" | trim)"
  username="$(printf '%s' "$username" | trim)"
  auth_url="$(printf '%s' "${auth_url:-}" | tr -d '\r' | trim)"

  local password pattern cmd
  password="$(decode_password 2>/dev/null || true)"
  pattern="$(load_pattern 2>/dev/null || true)"

  [[ -n "$password" && -n "$pattern" && -n "$k8s_url" && -n "$username" ]] || { echo "Login failed."; exit 1; }

  cmd="$(apply_pattern "$pattern" "$clustername" "$k8s_url" "$username" "$auth_url")"

  export KCL_CMD="$cmd"
  export KCL_PASSWORD="$password"
  export KCL_TIMEOUT="$KCL_TIMEOUT"
  export KCL_DEBUG="$KCL_DEBUG"

  local spid=""
  if [[ "$KCL_DEBUG" != "1" ]]; then
    spid="$(spinner_start)"
  else
    echo "DEBUG: KCL_HOME=$KCL_HOME"
    echo "DEBUG: running: $cmd"
  fi

  set +e
  expect <<'EOF'
set timeout -1

set t $env(KCL_TIMEOUT)
set debug $env(KCL_DEBUG)

if {$debug == "1"} {
  exp_internal 0
  log_user 1
} else {
  log_user 0
}

after [expr {$t * 1000}] { exit 124 }

spawn sh -lc $env(KCL_CMD)

set sent 0
expect {
  -re {(?i)(password|passcode|pin)[^\r\n]*[:? ]*$} {
    if {$sent == 0} {
      send -- "$env(KCL_PASSWORD)\r"
      set sent 1
    }
    exp_continue
  }
  -re {(?i)(enter|type)[^\r\n]*(password|passcode|pin)[^\r\n]*$} {
    if {$sent == 0} {
      send -- "$env(KCL_PASSWORD)\r"
      set sent 1
    }
    exp_continue
  }
  eof
}

catch wait result
set exit_status [lindex $result 3]
exit $exit_status
EOF
  rc=$?
  set -e

  if [[ "$KCL_DEBUG" != "1" ]]; then
    if [[ $rc -eq 0 ]]; then
      spinner_stop_with_message "$spid" "Logged in."
      exit 0
    elif [[ $rc -eq 124 ]]; then
      spinner_stop_with_message "$spid" "Login timed out."
      exit 124
    else
      spinner_stop_with_message "$spid" "Login failed."
      exit 1
    fi
  else
    if [[ $rc -eq 0 ]]; then
      echo "Logged in."
      exit 0
    elif [[ $rc -eq 124 ]]; then
      echo "Login timed out."
      exit 124
    else
      echo "Login failed."
      exit 1
    fi
  fi
}

main "$@"
