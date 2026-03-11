#!/bin/bash
set -eo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./cluster-capacity-by-tenants.sh [--cpu <value>] [--memory <value>] [--buffer-percent <0-99>]

Examples:
  ./cluster-capacity-by-tenants.sh
  ./cluster-capacity-by-tenants.sh --cpu 4 --memory 8Gi
  ./cluster-capacity-by-tenants.sh --cpu 1500m --memory 2048Mi --buffer-percent 10

Notes:
  - CPU examples: 500m, 2, 4.5
  - Memory examples: 512Mi, 8Gi, 2000M, 129e6
  - This script reads Capsule Tenant.spec.resourceQuotas.items[].hard
  - It totals tenant quota commitments, not live pod usage
  - Available now = allocable - tenant quota requests
  - Safe available = (allocable - buffer) - tenant quota requests
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
      printf "%.0f", v
    }' || return 1
  else
    awk -v n="$num" -v f="$factor" 'BEGIN {
      v = n * f
      printf "%.0f", v
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

context="$(kubectl config current-context 2>/dev/null || echo unknown)"

nodes_json="$(mktemp)"
tenants_json="$(mktemp)"
tenant_rows="$(mktemp)"

cleanup() {
  rm -f "$nodes_json" "$tenants_json" "$tenant_rows"
}
trap cleanup EXIT

log "Getting node data from cluster..."
kubectl get nodes -o json > "$nodes_json" || die "kubectl get nodes failed"

log "Getting Capsule tenants..."
kubectl get tenants.capsule.clastix.io -o json > "$tenants_json" 2>/dev/null \
  || kubectl get tenant -o json > "$tenants_json" 2>/dev/null \
  || die "Failed to get Capsule tenants. Tried: tenants.capsule.clastix.io and tenant"

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

tenant_count=0
total_quota_req_cpu=0
total_quota_req_mem=0
total_quota_lim_cpu=0
total_quota_lim_mem=0

log "Calculating Capsule tenant quota totals..."
while IFS=$'\x1f' read -r tenant scope req_cpu req_mem lim_cpu lim_mem; do
  [[ -z "$tenant" ]] && continue

  req_cpu_m="$(parse_cpu "${req_cpu:-0}")" || die "Cannot parse requests.cpu '$req_cpu' for tenant '$tenant'"
  req_mem_b="$(parse_mem "${req_mem:-0}")" || die "Cannot parse requests.memory '$req_mem' for tenant '$tenant'"
  lim_cpu_m="$(parse_cpu "${lim_cpu:-0}")" || die "Cannot parse limits.cpu '$lim_cpu' for tenant '$tenant'"
  lim_mem_b="$(parse_mem "${lim_mem:-0}")" || die "Cannot parse limits.memory '$lim_mem' for tenant '$tenant'"

  tenant_count=$(( tenant_count + 1 ))
  total_quota_req_cpu=$(( total_quota_req_cpu + req_cpu_m ))
  total_quota_req_mem=$(( total_quota_req_mem + req_mem_b ))
  total_quota_lim_cpu=$(( total_quota_lim_cpu + lim_cpu_m ))
  total_quota_lim_mem=$(( total_quota_lim_mem + lim_mem_b ))

  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$tenant" "$scope" "$req_cpu_m" "$req_mem_b" "$lim_cpu_m" "$lim_mem_b" >> "$tenant_rows"
done < <(
  jq -r '
    .items[]
    | .metadata.name as $tenant
    | if ((.spec.resourceQuotas.items // []) | length) == 0 then
        [$tenant, "Tenant", "0", "0", "0", "0"] | join("\u001f")
      else
        (
          (.spec.resourceQuotas.scope // "Tenant") as $defaultScope
          | [
              $tenant,
              $defaultScope,
              (
                [(.spec.resourceQuotas.items[]?.hard["requests.cpu"] // "0")]
                | join(",")
              ),
              (
                [(.spec.resourceQuotas.items[]?.hard["requests.memory"] // "0")]
                | join(",")
              ),
              (
                [(.spec.resourceQuotas.items[]?.hard["limits.cpu"] // "0")]
                | join(",")
              ),
              (
                [(.spec.resourceQuotas.items[]?.hard["limits.memory"] // "0")]
                | join(",")
              )
            ]
          | join("\u001f")
        )
      end
  ' "$tenants_json" | while IFS=$'\x1f' read -r tenant scope req_cpu_csv req_mem_csv lim_cpu_csv lim_mem_csv; do
      req_cpu_total=0
      req_mem_total=0
      lim_cpu_total=0
      lim_mem_total=0

      if [[ -n "$req_cpu_csv" ]]; then
        IFS=',' read -r -a arr <<< "$req_cpu_csv"
        for item in "${arr[@]}"; do
          [[ -z "$item" ]] && continue
          val="$(parse_cpu "$item")" || exit 1
          req_cpu_total=$(( req_cpu_total + val ))
        done
      fi

      if [[ -n "$req_mem_csv" ]]; then
        IFS=',' read -r -a arr <<< "$req_mem_csv"
        for item in "${arr[@]}"; do
          [[ -z "$item" ]] && continue
          val="$(parse_mem "$item")" || exit 1
          req_mem_total=$(( req_mem_total + val ))
        done
      fi

      if [[ -n "$lim_cpu_csv" ]]; then
        IFS=',' read -r -a arr <<< "$lim_cpu_csv"
        for item in "${arr[@]}"; do
          [[ -z "$item" ]] && continue
          val="$(parse_cpu "$item")" || exit 1
          lim_cpu_total=$(( lim_cpu_total + val ))
        done
      fi

      if [[ -n "$lim_mem_csv" ]]; then
        IFS=',' read -r -a arr <<< "$lim_mem_csv"
        for item in "${arr[@]}"; do
          [[ -z "$item" ]] && continue
          val="$(parse_mem "$item")" || exit 1
          lim_mem_total=$(( lim_mem_total + val ))
        done
      fi

      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "$tenant" "$scope" "$req_cpu_total" "$req_mem_total" "$lim_cpu_total" "$lim_mem_total"
    done
)

raw_free_cpu=$(( total_alloc_cpu - total_quota_req_cpu ))
raw_free_mem=$(( total_alloc_mem - total_quota_req_mem ))

safe_capacity_cpu="$(awk -v a="$total_alloc_cpu" -v p="$BUFFER_PERCENT" 'BEGIN { printf "%.0f", a * (100 - p) / 100 }')"
safe_capacity_mem="$(awk -v a="$total_alloc_mem" -v p="$BUFFER_PERCENT" 'BEGIN { printf "%.0f", a * (100 - p) / 100 }')"

safe_free_cpu=$(( safe_capacity_cpu - total_quota_req_cpu ))
safe_free_mem=$(( safe_capacity_mem - total_quota_req_mem ))

printf '\n'
printf 'Context: %s\n' "$context"
printf 'Nodes counted: %s\n' "$node_count"
printf 'Tenants counted: %s\n' "$tenant_count"
printf '\n'
printf 'PER TENANT QUOTA SUMMARY\n'
printf '%-35s %-10s %-22s %-16s %-22s %-16s\n' "TENANT" "SCOPE" "REQ CPU" "REQ RAM" "LIM CPU" "LIM RAM"
printf '%-35s %-10s %-22s %-16s %-22s %-16s\n' "-----------------------------------" "----------" "----------------------" "----------------" "----------------------" "----------------"
while IFS=$'\x1f' read -r tenant scope req_cpu_m req_mem_b lim_cpu_m lim_mem_b; do
  printf '%-35s %-10s %-22s %-16s %-22s %-16s\n' \
    "$tenant" \
    "$scope" \
    "$(format_cpu "$req_cpu_m")" \
    "$(format_mem "$req_mem_b")" \
    "$(format_cpu "$lim_cpu_m")" \
    "$(format_mem "$lim_mem_b")"
done < "$tenant_rows"

printf '\n'
printf 'CLUSTER ALLOCABLE\n'
printf '  CPU: %s\n' "$(format_cpu "$total_alloc_cpu")"
printf '  RAM: %s\n' "$(format_mem "$total_alloc_mem")"
printf '\n'
printf 'TOTAL TENANT QUOTA COMMITMENT\n'
printf '  requests.cpu:    %s  [%s%% of allocable]\n' "$(format_cpu "$total_quota_req_cpu")" "$(percent_of "$total_quota_req_cpu" "$total_alloc_cpu")"
printf '  requests.memory: %s  [%s%% of allocable]\n' "$(format_mem "$total_quota_req_mem")" "$(percent_of "$total_quota_req_mem" "$total_alloc_mem")"
printf '  limits.cpu:      %s  [%s%% of allocable]\n' "$(format_cpu "$total_quota_lim_cpu")" "$(percent_of "$total_quota_lim_cpu" "$total_alloc_cpu")"
printf '  limits.memory:   %s  [%s%% of allocable]\n' "$(format_mem "$total_quota_lim_mem")" "$(percent_of "$total_quota_lim_mem" "$total_alloc_mem")"
printf '\n'
printf 'AVAILABLE AGAINST TENANT REQUEST QUOTAS\n'
printf '  CPU: %s\n' "$(format_cpu "$raw_free_cpu")"
printf '  RAM: %s\n' "$(format_mem "$raw_free_mem")"
printf '\n'
printf 'SAFE AVAILABLE WITH %s%% BUFFER\n' "$BUFFER_PERCENT"
printf '  CPU: %s\n' "$(format_cpu "$safe_free_cpu")"
printf '  RAM: %s\n' "$(format_mem "$safe_free_mem")"
printf '\n'

if [[ -n "$REQUEST_CPU" || -n "$REQUEST_MEM" ]]; then
  want_cpu=0
  want_mem=0

  if [[ -n "$REQUEST_CPU" ]]; then
    want_cpu="$(parse_cpu "$REQUEST_CPU")" || die "Cannot parse requested CPU value: $REQUEST_CPU"
  fi

  if [[ -n "$REQUEST_MEM" ]]; then
    want_mem="$(parse_mem "$REQUEST_MEM")" || die "Cannot parse requested memory value: $REQUEST_MEM"
  fi

  quota_fit="YES"
  safe_fit="YES"

  (( want_cpu > raw_free_cpu )) && quota_fit="NO"
  (( want_mem > raw_free_mem )) && quota_fit="NO"

  (( want_cpu > safe_free_cpu )) && safe_fit="NO"
  (( want_mem > safe_free_mem )) && safe_fit="NO"

  after_raw_cpu=$(( raw_free_cpu - want_cpu ))
  after_raw_mem=$(( raw_free_mem - want_mem ))
  after_safe_cpu=$(( safe_free_cpu - want_cpu ))
  after_safe_mem=$(( safe_free_mem - want_mem ))

  printf 'NEW TENANT QUOTA REQUEST CHECK\n'
  printf '  Requested CPU: %s\n' "$(format_cpu "$want_cpu")"
  printf '  Requested RAM: %s\n' "$(format_mem "$want_mem")"
  printf '\n'
  printf 'RESULT\n'
  printf '  Fits by total tenant quota math: %s\n' "$quota_fit"
  printf '  Fits by safe buffer:             %s\n' "$safe_fit"
  printf '\n'
  printf 'HEADROOM AFTER THIS REQUEST\n'
  printf '  Remaining CPU: %s\n' "$(format_cpu "$after_raw_cpu")"
  printf '  Remaining RAM: %s\n' "$(format_mem "$after_raw_mem")"
  printf '  Safe CPU:      %s\n' "$(format_cpu "$after_safe_cpu")"
  printf '  Safe RAM:      %s\n' "$(format_mem "$after_safe_mem")"
  printf '\n'

  if [[ "$safe_fit" == "YES" ]]; then
    exit 0
  else
    exit 2
  fi
fi