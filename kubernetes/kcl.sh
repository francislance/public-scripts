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

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

need() {
  command -v "$1" >/dev/null 2>&1 || exit 127
}

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
    | trim
}

apply_pattern() {
  local pat="$1"
  pat="${pat//\{clustername\}/$2}"
  pat="${pat//\{kubernetes-api-url\}/$3}"
  pat="${pat//\{username\}/$4}"
  pat="${pat//\{auth-api-url\}/$5}"
  printf '%s' "$pat"
}

spinner_start() {
  # prints: Logging in. .. ... (updates every second)
  (
    local dots=1
    while true; do
      printf '\rLogging in%*s' "$dots" ''
      dots=$((dots + 1))
      if [[ $dots -gt 3 ]]; then dots=1; fi
      sleep 1
    done
  ) &
  echo $!
}

spinner_stop() {
  local pid="$1"
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  # clear line
  printf '\r%*s\r' 40 ''
}

main() {
  # Hard requirements
  need expect
  need awk
  need base64

  # No chatter; just fail quietly with a minimal message
  [[ -n "$CLUSTER" ]] || { echo "Login failed."; exit 1; }
  [[ -f "$CSV_FILE" ]] || { echo "Login failed."; exit 1; }
  [[ -f "$PASS_B64_FILE" ]] || { echo "Login failed."; exit 1; }
  [[ -f "$PATTERN_FILE" ]] || { echo "Login failed."; exit 1; }

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
  auth_url="$(printf '%s' "$auth_url" | trim)"

  [[ -n "$k8s_url" && -n "$username" && -n "$auth_url" ]] || { echo "Login failed."; exit 1; }

  local password pattern cmd
  password="$(decode_password 2>/dev/null || true)"
  [[ -n "$password" ]] || { echo "Login failed."; exit 1; }

  pattern="$(load_pattern 2>/dev/null || true)"
  [[ -n "$pattern" ]] || { echo "Login failed."; exit 1; }

  cmd="$(apply_pattern "$pattern" "$clustername" "$k8s_url" "$username" "$auth_url")"

  export KCL_CMD="$cmd"
  export KCL_PASSWORD="$password"

  # Start minimal animation
  local spid
  spid="$(spinner_start)"

  # Run expect silently (no stdout from skectl)
  set +e
  expect >/dev/null 2>&1 <<'EOF'
set timeout -1
log_user 0
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

  spinner_stop "$spid"

  if [[ $rc -eq 0 ]]; then
    # show nothing else; keep it clean
    exit 0
  fi

  echo "Login failed."
  exit 1
}

main "$@"
