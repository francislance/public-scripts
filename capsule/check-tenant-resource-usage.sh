#!/usr/bin/env bash
set -euo pipefail

# --- Dependencies check ------------------------------------------------------
for bin in kubectl jq bc; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' is required but not installed or not in PATH." >&2
    exit 1
  fi
done

# --- Args --------------------------------------------------------------------
TENANT="${1:-}"

if [[ -z "$TENANT" ]]; then
  echo "Usage: $0 TENANT_NAME" >&2
  exit 1
fi

# --- Helper: parse CPU string -> millicores (int) ---------------------------
# "500m" -> 500
# "1"    -> 1000
# "0.5"  -> 500
parse_cpu_millicores() {
  local v="$1"
  [[ -z "$v" ]] && { echo 0; return; }

  if [[ "$v" == *m ]]; then
    echo "${v%m}"
  else
    # cores -> millicores
    local res
    res=$(printf 'scale=3; %s*1000\n' "$v" | bc)
    printf '%s\n' "$res" | awk -F. '{print $1}'
  fi
}

# --- Helper: parse memory string -> bytes (int) -----------------------------
# Supports: Ki, Mi, Gi, Ti, Pi, Ei and K, M, G, T, P, E.
parse_mem_bytes() {
  local v="$1"
  [[ -z "$v" ]] && { echo 0; return; }

  local num unit
  if [[ "$v" =~ ^([0-9.]+)([KMGTEP]i?)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    # Fallback: treat as plain bytes
    echo "$v"
    return
  fi

  local factor
  case "$unit" in
    Ki) factor=1024 ;;
    Mi) factor=1048576 ;;             # 1024^2
    Gi) factor=1073741824 ;;          # 1024^3
    Ti) factor=1099511627776 ;;       # 1024^4
    Pi) factor=1125899906842624 ;;    # 1024^5
    Ei) factor=1152921504606846976 ;; # 1024^6
    K)  factor=1000 ;;
    M)  factor=1000000 ;;
    G)  factor=1000000000 ;;
    T)  factor=1000000000000 ;;
    P)  factor=1000000000000000 ;;
    E)  factor=1000000000000000000 ;;
    ""|*) factor=1 ;;
  esac

  local res
  res=$(printf 'scale=3; %s*%s\n' "$num" "$factor" | bc)
  printf '%s\n' "$res" | awk -F. '{print $1}'
}

# --- Helper: formatting ------------------------------------------------------
format_cpu_cores() {
  local m="$1"
  local cores
  cores=$(printf 'scale=3; %s/1000\n' "$m" | bc)
  echo "${cores} cores"
}

format_bytes() {
  local bytes="$1"

  if (( bytes == 0 )); then
    echo "0 B"
    return
  fi

  local unit divisor
  if   (( bytes >= 1099511627776 )); then
    unit="TiB"; divisor=1099511627776
  elif (( bytes >= 1073741824 )); then
    unit="GiB"; divisor=1073741824
  elif (( bytes >= 1048576 )); then
    unit="MiB"; divisor=1048576
  elif (( bytes >= 1024 )); then
    unit="KiB"; divisor=1024
  else
    echo "${bytes} B"
    return
  fi

  local val
  val=$(printf 'scale=2; %s/%s\n' "$bytes" "$divisor" | bc)
  echo "${val} ${unit}"
}

percent() {
  local used="$1"
  local limit="$2"
  if (( limit == 0 )); then
    echo "n/a"
    return
  fi
  local val
  val=$(printf 'scale=2; %s*100/%s\n' "$used" "$limit" | bc)
  printf '%s%%' "$val"
}

# --- Get namespaces from Capsule Tenant -------------------------------------
namespaces=$(kubectl get tenant "$TENANT" -o jsonpath='{.status.namespaces[*]}' 2>/dev/null || true)

if [[ -z "$namespaces" ]]; then
  echo "Tenant '$TENANT' has no namespaces in status.namespaces or tenant not found." >&2
  exit 1
fi

# --- Totals ------------------------------------------------------------------
# Pod sums
total_limits_cpu_m=0
total_limits_mem_b=0
total_requests_cpu_m=0
total_requests_mem_b=0

# ResourceQuota sums
quota_limits_cpu_m=0
quota_limits_mem_b=0
quota_requests_cpu_m=0
quota_requests_mem_b=0

# --- Main loop over namespaces ----------------------------------------------
for ns in $namespaces; do
  # Sum pod LIMITS (containers + initContainers + ephemeralContainers)
  while read -r cpu; do
    [[ -z "$cpu" ]] && continue
    mc=$(parse_cpu_millicores "$cpu")
    total_limits_cpu_m=$(( total_limits_cpu_m + mc ))
  done < <(
    kubectl get pods -n "$ns" -o json \
    | jq -r '.items[]
      | (.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?)
      | .resources.limits.cpu? // empty'
  )

  while read -r mem; do
    [[ -z "$mem" ]] && continue
    bytes=$(parse_mem_bytes "$mem")
    total_limits_mem_b=$(( total_limits_mem_b + bytes ))
  done < <(
    kubectl get pods -n "$ns" -o json \
    | jq -r '.items[]
      | (.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?)
      | .resources.limits.memory? // empty'
  )

  # Sum pod REQUESTS
  while read -r cpu; do
    [[ -z "$cpu" ]] && continue
    mc=$(parse_cpu_millicores "$cpu")
    total_requests_cpu_m=$(( total_requests_cpu_m + mc ))
  done < <(
    kubectl get pods -n "$ns" -o json \
    | jq -r '.items[]
      | (.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?)
      | .resources.requests.cpu? // empty'
  )

  while read -r mem; do
    [[ -z "$mem" ]] && continue
    bytes=$(parse_mem_bytes "$mem")
    total_requests_mem_b=$(( total_requests_mem_b + bytes ))
  done < <(
    kubectl get pods -n "$ns" -o json \
    | jq -r '.items[]
      | (.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?)
      | .resources.requests.memory? // empty'
  )

  # Sum ResourceQuota limits.* and requests.* (per namespace)
  rq_json=$(kubectl get resourcequota -n "$ns" -o json)

  # limits.cpu
  while read -r cpu_q; do
    [[ -z "$cpu_q" ]] && continue
    mc_q=$(parse_cpu_millicores "$cpu_q")
    quota_limits_cpu_m=$(( quota_limits_cpu_m + mc_q ))
  done < <(echo "$rq_json" | jq -r '.items[].spec.hard["limits.cpu"] // empty')

  # limits.memory
  while read -r mem_q; do
    [[ -z "$mem_q" ]] && continue
    bytes_q=$(parse_mem_bytes "$mem_q")
    quota_limits_mem_b=$(( quota_limits_mem_b + bytes_q ))
  done < <(echo "$rq_json" | jq -r '.items[].spec.hard["limits.memory"] // empty')

  # requests.cpu
  while read -r cpu_q; do
    [[ -z "$cpu_q" ]] && continue
    mc_q=$(parse_cpu_millicores "$cpu_q")
    quota_requests_cpu_m=$(( quota_requests_cpu_m + mc_q ))
  done < <(echo "$rq_json" | jq -r '.items[].spec.hard["requests.cpu"] // empty')

  # requests.memory
  while read -r mem_q; do
    [[ -z "$mem_q" ]] && continue
    bytes_q=$(parse_mem_bytes "$mem_q")
    quota_requests_mem_b=$(( quota_requests_mem_b + bytes_q ))
  done < <(echo "$rq_json" | jq -r '.items[].spec.hard["requests.memory"] // empty')
done

# --- Output ------------------------------------------------------------------
echo "Capsule Tenant : $TENANT"
echo "Namespaces     : $namespaces"
echo

echo "=== Pod resource REQUESTS (sum across tenant namespaces) ==="
echo "CPU requests    : $(format_cpu_cores "$total_requests_cpu_m")"
echo "Memory requests : $(format_bytes "$total_requests_mem_b")"
echo

echo "=== Pod resource LIMITS (sum across tenant namespaces) ==="
echo "CPU limits      : $(format_cpu_cores "$total_limits_cpu_m")"
echo "Memory limits   : $(format_bytes "$total_limits_mem_b")"
echo

echo "=== ResourceQuota hard REQUESTS (sum across tenant namespaces) ==="
echo "requests.cpu    : $(format_cpu_cores "$quota_requests_cpu_m")"
echo "requests.memory : $(format_bytes "$quota_requests_mem_b")"
echo

echo "=== ResourceQuota hard LIMITS (sum across tenant namespaces) ==="
echo "limits.cpu      : $(format_cpu_cores "$quota_limits_cpu_m")"
echo "limits.memory   : $(format_bytes "$quota_limits_mem_b")"
echo

echo "=== Usage vs Quota based on REQUESTS ==="
echo "CPU    : $(format_cpu_cores "$total_requests_cpu_m") / $(format_cpu_cores "$quota_requests_cpu_m")  ($(percent "$total_requests_cpu_m" "$quota_requests_cpu_m"))"
echo "Memory : $(format_bytes "$total_requests_mem_b") / $(format_bytes "$quota_requests_mem_b")  ($(percent "$total_requests_mem_b" "$quota_requests_mem_b"))"
echo

echo "=== Usage vs Quota based on LIMITS ==="
echo "CPU    : $(format_cpu_cores "$total_limits_cpu_m") / $(format_cpu_cores "$quota_limits_cpu_m")  ($(percent "$total_limits_cpu_m" "$quota_limits_cpu_m"))"
echo "Memory : $(format_bytes "$total_limits_mem_b") / $(format_bytes "$quota_limits_mem_b")  ($(percent "$total_limits_mem_b" "$quota_limits_mem_b"))"
