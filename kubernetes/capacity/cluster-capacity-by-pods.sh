#!/bin/bash
set -eo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./cluster-capacity-by-pods.sh [--cpu <value>] [--memory <value>] [--buffer-percent <0-99>]

Examples:
  ./cluster-capacity-by-pods.sh
  ./cluster-capacity-by-pods.sh --cpu 4 --memory 8Gi
  ./cluster-capacity-by-pods.sh --cpu 1500m --memory 2048Mi --buffer-percent 10

Notes:
  - CPU examples: 500m, 2, 4.5
  - Memory examples: 512Mi, 8Gi, 2000M, 129e6
  - Available now = allocable - scheduled pod requests
  - Safe available = (allocable - buffer) - scheduled pod requests
  - Default buffer = 10%
USAGE
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# ------------------------------------------------------------------------------
# Parse generic Kubernetes quantity into base units
# kind=cpu -> output millicores
# kind=mem -> output bytes
# Supports:
#   plain numbers, decimals, exponent notation
#   binary suffixes: Ki Mi Gi Ti Pi Ei
#   decimal suffixes: n u m k K M G T P E
# ------------------------------------------------------------------------------
parse_quantity() {
  local kind="$1"
  local q="${2:-0}"
  local num suffix factor

  [[ -z "$q" || "$q" == "null" ]] && { echo 0; return 0; }

  if [[ "$q" =~ ^([+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?)(Ki|Mi|Gi|Ti|Pi|Ei|n|u|m|k|K|M|G|T|P|E)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[5]}"
  else
    return 1
  fi

  case "$suffix" in
    "")  factor="1" ;;
    n)   factor="0.000000001" ;;
    u)   factor="0.000001" ;;
    m)   factor="0.001" ;;
    k|K) factor="1000" ;;
    M)   factor="1000000" ;;
    G)   factor="1000000000" ;;
    T)   factor="1000000000000" ;;
    P)   factor="1000000000000000" ;;
    E)   factor="1000000000000000000" ;;
    Ki)  factor="1024" ;;
    Mi)  factor="1048576" ;;
    Gi)  factor="1073741824" ;;
    Ti)  factor="1099511627776" ;;
    Pi)  factor="1125899906842624" ;;
    Ei)  factor="1152921504606846976" ;;
    *) return 1 ;;
  esac

  if [[ "$kind" == "cpu" ]]; then
    awk -v n="$num" -v f="$factor" 'BEGIN {
      v = n * f * 1000
      if (v >= 0) printf "%.0f", v
      else printf "%.0f", v
    }' || return 1
  else
    awk -v n="$num" -v f="$factor" 'BEGIN {
      v = n * f
      if (v >= 0) printf "%.0f", v
      else printf "%.0f", v
    }' || return 1
  fi
}

parse_cpu() {
  parse_quantity cpu "${1:-0}"
}

parse_mem() {
  parse_quantity mem "${1:-0}"
}

format_cpu() {
  local m="${1:-0}"
  awk -v m="$m" 'BEGIN { printf "%.3f cores (%dm)", m / 1000, m }'
}

format_mem() {
  local b="${1:-0}"
  awk -v b="$b" '
    BEGIN {
      sign = ""
      if (b < 0) {
        sign = "-"
        b = -b
      }

      kib = 1024
      mib = 1024 * 1024
      gib = 1024 * 1024 * 1024
      tib = gib * 1024
      pib = tib * 1024

      if      (b >= pib) printf "%s%.2f Pi", sign, b / pib
      else if (b >= tib) printf "%s%.2f Ti", sign, b / tib
      else if (b >= gib) printf "%s%.2f Gi", sign, b / gib
      else if (b >= mib) printf "%s%.2f Mi", sign, b / mib
      else if (b >= kib) printf "%s%.2f Ki", sign, b / kib
      else               printf "%s%d B", sign, b
    }
  '
}

percent_of() {
  local part="${1:-0}"
  local whole="${2:-0}"
  awk -v p="$part" -v w="$whole" 'BEGIN {
    if (w == 0) printf "0.00"
    else printf "%.2f", (p / w) * 100
  }'
}

sum_csv_cpu() {
  local csv="${1:-}"
  local total=0
  local item val
  local arr

  [[ -z "$csv" ]] && { echo 0; return 0; }

  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    val="$(parse_cpu "$item")" || return 1
    total=$(( total + val ))
  done

  echo "$total"
}

max_csv_cpu() {
  local csv="${1:-}"
  local max=0
  local item val
  local arr

  [[ -z "$csv" ]] && { echo 0; return 0; }

  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    val="$(parse_cpu "$item")" || return 1
    (( val > max )) && max=$val
  done

  echo "$max"
}

sum_csv_mem() {
  local csv="${1:-}"
  local total=0
  local item val
  local arr

  [[ -z "$csv" ]] && { echo 0; return 0; }

  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    val="$(parse_mem "$item")" || return 1
    total=$(( total + val ))
  done

  echo "$total"
}

max_csv_mem() {
  local csv="${1:-}"
  local max=0
  local item val
  local arr

  [[ -z "$csv" ]] && { echo 0; return 0; }

  IFS=',' read -r -a arr <<< "$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    val="$(parse_mem "$item")" || return 1
    (( val > max )) && max=$val
  done

  echo "$max"
}

max_int() {
  local a="${1:-0}"
  local b="${2:-0}"
  if (( a > b )); then
    echo "$a"
  else
    echo "$b"
  fi
}

REQUEST_CPU=""
REQUEST_MEM=""
BUFFER_PERCENT=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu)
      REQUEST_CPU="${2:?Missing value for --cpu}"
      shift 2
      ;;
    --memory|--ram)
      REQUEST_MEM="${2:?Missing value for --memory}"
      shift 2
      ;;
    --buffer-percent)
      BUFFER_PERCENT="${2:?Missing value for --buffer-percent}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if ! [[ "$BUFFER_PERCENT" =~ ^[0-9]+$ ]] || (( BUFFER_PERCENT < 0 || BUFFER_PERCENT >= 100 )); then
  die "--buffer-percent must be an integer between 0 and 99"
fi

require_cmd kubectl
require_cmd jq
require_cmd awk
require_cmd mktemp
require_cmd date

context="$(kubectl config current-context 2>/dev/null || echo unknown)"

nodes_json="$(mktemp)"
pods_json="$(mktemp)"

cleanup() {
  rm -f "$nodes_json" "$pods_json"
}
trap cleanup EXIT

log "Getting node data from cluster..."
kubectl get nodes -o json > "$nodes_json" || die "kubectl get nodes failed"

log "Getting pod data from cluster..."
kubectl get pods -A -o json > "$pods_json" || die "kubectl get pods -A failed"

node_count=0
total_alloc_cpu=0
total_alloc_mem=0

log "Calculating allocable CPU and RAM..."
while IFS=$'\t' read -r node cpu mem; do
  [[ -z "$node" ]] && continue

  cpu_m="$(parse_cpu "$cpu")" || die "Cannot parse allocable CPU '$cpu' on node '$node'"
  mem_b="$(parse_mem "$mem")" || die "Cannot parse allocable memory '$mem' on node '$node'"

  node_count=$(( node_count + 1 ))
  total_alloc_cpu=$(( total_alloc_cpu + cpu_m ))
  total_alloc_mem=$(( total_alloc_mem + mem_b ))
done < <(
  jq -r '.items[] | [.metadata.name, .status.allocatable.cpu, .status.allocatable.memory] | @tsv' "$nodes_json"
)

pod_count=0
total_req_cpu=0
total_req_mem=0
total_lim_cpu=0
total_lim_mem=0

log "Calculating scheduled pod requests and limits..."
while IFS=$'\x1f' read -r ns name node_name app_req_cpu init_req_cpu overhead_cpu app_req_mem init_req_mem overhead_mem app_lim_cpu init_lim_cpu app_lim_mem init_lim_mem; do
  [[ -z "$ns" ]] && continue

  app_req_cpu_sum="$(sum_csv_cpu "$app_req_cpu")" || die "Cannot parse app CPU requests '$app_req_cpu' for pod $ns/$name"
  init_req_cpu_max="$(max_csv_cpu "$init_req_cpu")" || die "Cannot parse init CPU requests '$init_req_cpu' for pod $ns/$name"
  over_cpu="$(parse_cpu "$overhead_cpu")" || die "Cannot parse overhead CPU '$overhead_cpu' for pod $ns/$name"
  pod_req_cpu=$(( $(max_int "$app_req_cpu_sum" "$init_req_cpu_max") + over_cpu ))

  app_req_mem_sum="$(sum_csv_mem "$app_req_mem")" || die "Cannot parse app memory requests '$app_req_mem' for pod $ns/$name"
  init_req_mem_max="$(max_csv_mem "$init_req_mem")" || die "Cannot parse init memory requests '$init_req_mem' for pod $ns/$name"
  over_mem="$(parse_mem "$overhead_mem")" || die "Cannot parse overhead memory '$overhead_mem' for pod $ns/$name"
  pod_req_mem=$(( $(max_int "$app_req_mem_sum" "$init_req_mem_max") + over_mem ))

  app_lim_cpu_sum="$(sum_csv_cpu "$app_lim_cpu")" || die "Cannot parse app CPU limits '$app_lim_cpu' for pod $ns/$name"
  init_lim_cpu_max="$(max_csv_cpu "$init_lim_cpu")" || die "Cannot parse init CPU limits '$init_lim_cpu' for pod $ns/$name"
  pod_lim_cpu=$(( $(max_int "$app_lim_cpu_sum" "$init_lim_cpu_max") + over_cpu ))

  app_lim_mem_sum="$(sum_csv_mem "$app_lim_mem")" || die "Cannot parse app memory limits '$app_lim_mem' for pod $ns/$name"
  init_lim_mem_max="$(max_csv_mem "$init_lim_mem")" || die "Cannot parse init memory limits '$init_lim_mem' for pod $ns/$name"
  pod_lim_mem=$(( $(max_int "$app_lim_mem_sum" "$init_lim_mem_max") + over_mem ))

  pod_count=$(( pod_count + 1 ))
  total_req_cpu=$(( total_req_cpu + pod_req_cpu ))
  total_req_mem=$(( total_req_mem + pod_req_mem ))
  total_lim_cpu=$(( total_lim_cpu + pod_lim_cpu ))
  total_lim_mem=$(( total_lim_mem + pod_lim_mem ))
done < <(
  jq -r '
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | [
        .metadata.namespace,
        .metadata.name,
        .spec.nodeName,
        ([.spec.containers[]?     | .resources.requests.cpu    // "0"] | join(",")),
        ([.spec.initContainers[]? | .resources.requests.cpu    // "0"] | join(",")),
        (.spec.overhead.cpu // "0"),
        ([.spec.containers[]?     | .resources.requests.memory // "0"] | join(",")),
        ([.spec.initContainers[]? | .resources.requests.memory // "0"] | join(",")),
        (.spec.overhead.memory // "0"),
        ([.spec.containers[]?     | .resources.limits.cpu      // "0"] | join(",")),
        ([.spec.initContainers[]? | .resources.limits.cpu      // "0"] | join(",")),
        ([.spec.containers[]?     | .resources.limits.memory   // "0"] | join(",")),
        ([.spec.initContainers[]? | .resources.limits.memory   // "0"] | join(","))
      ]
    | join("\u001f")
  ' "$pods_json"
)

log "Checking containers with missing requests or limits..."
missing_cpu_req="$(jq '
  [
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | .spec.containers[]?
    | select((.resources.requests.cpu // null) == null)
  ] | length
' "$pods_json")"

missing_mem_req="$(jq '
  [
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | .spec.containers[]?
    | select((.resources.requests.memory // null) == null)
  ] | length
' "$pods_json")"

missing_cpu_lim="$(jq '
  [
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | .spec.containers[]?
    | select((.resources.limits.cpu // null) == null)
  ] | length
' "$pods_json")"

missing_mem_lim="$(jq '
  [
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | .spec.containers[]?
    | select((.resources.limits.memory // null) == null)
  ] | length
' "$pods_json")"

timestamp="$(date +%Y%m%d_%H%M%S)"
csv_file="missing-pod-resource-flags_${timestamp}.csv"

jq -r '
  ["namespace","pod_name","container_name","cpu_request_missing","cpu_limit_missing","ram_request_missing","ram_limit_missing"],
  (
    .items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(.spec.nodeName != null)
    | .metadata.namespace as $ns
    | .metadata.name as $pod
    | .spec.containers[]?
    | {
        ns: $ns,
        pod: $pod,
        container: (.name // ""),
        cpu_req: (if ((.resources.requests.cpu // null) == null) then "YES" else "" end),
        cpu_lim: (if ((.resources.limits.cpu // null) == null) then "YES" else "" end),
        mem_req: (if ((.resources.requests.memory // null) == null) then "YES" else "" end),
        mem_lim: (if ((.resources.limits.memory // null) == null) then "YES" else "" end)
      }
    | select(.cpu_req == "YES" or .cpu_lim == "YES" or .mem_req == "YES" or .mem_lim == "YES")
    | [.ns, .pod, .container, .cpu_req, .cpu_lim, .mem_req, .mem_lim]
  )
  | @csv
' "$pods_json" > "$csv_file" || die "Failed to generate CSV report"

log "CSV generated: $csv_file"

raw_free_cpu=$(( total_alloc_cpu - total_req_cpu ))
raw_free_mem=$(( total_alloc_mem - total_req_mem ))

safe_capacity_cpu="$(awk -v a="$total_alloc_cpu" -v p="$BUFFER_PERCENT" 'BEGIN { printf "%.0f", a * (100 - p) / 100 }')"
safe_capacity_mem="$(awk -v a="$total_alloc_mem" -v p="$BUFFER_PERCENT" 'BEGIN { printf "%.0f", a * (100 - p) / 100 }')"

safe_free_cpu=$(( safe_capacity_cpu - total_req_cpu ))
safe_free_mem=$(( safe_capacity_mem - total_req_mem ))

printf '\n'
printf 'Context: %s\n' "$context"
printf 'Nodes counted: %s\n' "$node_count"
printf 'Scheduled active pods counted: %s\n' "$pod_count"
printf 'Missing-resource CSV: %s\n' "$csv_file"
printf '\n'
printf 'ALLOCABLE\n'
printf '  CPU: %s\n' "$(format_cpu "$total_alloc_cpu")"
printf '  RAM: %s\n' "$(format_mem "$total_alloc_mem")"
printf '\n'
printf 'REQUESTS\n'
printf '  CPU: %s  [%s%% of allocable]\n' "$(format_cpu "$total_req_cpu")" "$(percent_of "$total_req_cpu" "$total_alloc_cpu")"
printf '  RAM: %s  [%s%% of allocable]\n' "$(format_mem "$total_req_mem")" "$(percent_of "$total_req_mem" "$total_alloc_mem")"
printf '\n'
printf 'LIMITS\n'
printf '  CPU: %s  [%s%% of allocable]\n' "$(format_cpu "$total_lim_cpu")" "$(percent_of "$total_lim_cpu" "$total_alloc_cpu")"
printf '  RAM: %s  [%s%% of allocable]\n' "$(format_mem "$total_lim_mem")" "$(percent_of "$total_lim_mem" "$total_alloc_mem")"
printf '\n'
printf 'AVAILABLE TO SCHEDULE NOW (allocable - scheduled requests)\n'
printf '  CPU: %s\n' "$(format_cpu "$raw_free_cpu")"
printf '  RAM: %s\n' "$(format_mem "$raw_free_mem")"
printf '\n'
printf 'SAFE AVAILABLE WITH %s%% BUFFER\n' "$BUFFER_PERCENT"
printf '  CPU: %s\n' "$(format_cpu "$safe_free_cpu")"
printf '  RAM: %s\n' "$(format_mem "$safe_free_mem")"
printf '\n'

if (( missing_cpu_req > 0 || missing_mem_req > 0 || missing_cpu_lim > 0 || missing_mem_lim > 0 )); then
  printf 'WARNING\n'
  printf '  Containers missing CPU request: %s\n' "$missing_cpu_req"
  printf '  Containers missing RAM request: %s\n' "$missing_mem_req"
  printf '  Containers missing CPU limit:   %s\n' "$missing_cpu_lim"
  printf '  Containers missing RAM limit:   %s\n' "$missing_mem_lim"
  printf '  Note: if requests are missing, remaining capacity can look better than the real situation.\n'
  printf '\n'
fi

if [[ -n "$REQUEST_CPU" || -n "$REQUEST_MEM" ]]; then
  want_cpu=0
  want_mem=0

  if [[ -n "$REQUEST_CPU" ]]; then
    want_cpu="$(parse_cpu "$REQUEST_CPU")" || die "Cannot parse requested CPU value: $REQUEST_CPU"
  fi

  if [[ -n "$REQUEST_MEM" ]]; then
    want_mem="$(parse_mem "$REQUEST_MEM")" || die "Cannot parse requested memory value: $REQUEST_MEM"
  fi

  scheduler_fit="YES"
  safe_fit="YES"

  (( want_cpu > raw_free_cpu )) && scheduler_fit="NO"
  (( want_mem > raw_free_mem )) && scheduler_fit="NO"

  (( want_cpu > safe_free_cpu )) && safe_fit="NO"
  (( want_mem > safe_free_mem )) && safe_fit="NO"

  after_raw_cpu=$(( raw_free_cpu - want_cpu ))
  after_raw_mem=$(( raw_free_mem - want_mem ))
  after_safe_cpu=$(( safe_free_cpu - want_cpu ))
  after_safe_mem=$(( safe_free_mem - want_mem ))

  printf 'NEW REQUEST CHECK\n'
  printf '  Requested CPU: %s\n' "$(format_cpu "$want_cpu")"
  printf '  Requested RAM: %s\n' "$(format_mem "$want_mem")"
  printf '\n'
  printf 'RESULT\n'
  printf '  Fits by scheduler math: %s\n' "$scheduler_fit"
  printf '  Fits by safe buffer:    %s\n' "$safe_fit"
  printf '\n'
  printf 'HEADROOM AFTER THIS REQUEST\n'
  printf '  Scheduler remaining CPU: %s\n' "$(format_cpu "$after_raw_cpu")"
  printf '  Scheduler remaining RAM: %s\n' "$(format_mem "$after_raw_mem")"
  printf '  Safe remaining CPU:      %s\n' "$(format_cpu "$after_safe_cpu")"
  printf '  Safe remaining RAM:      %s\n' "$(format_mem "$after_safe_mem")"
  printf '\n'

  if [[ "$safe_fit" == "YES" ]]; then
    exit 0
  else
    exit 2
  fi
fi