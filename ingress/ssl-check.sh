#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ssl-check <namespace> <ingress>

Checks that the TLS certificate(s) referenced by an Ingress cover the Ingress host(s).
- Reads: spec.rules[].host and spec.tls[].secretName/spec.tls[].hosts
- Verifies each Ingress host is present in cert SAN (or CN fallback) incl. wildcards (*.example.com)

Requirements:
  kubectl, openssl, base64
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 2; }; }

ns="${1:-}"
ing="${2:-}"
[[ -z "${ns}" || -z "${ing}" ]] && { usage; exit 2; }

need kubectl
need openssl
need base64

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------- helpers ----------
trim() { awk '{$1=$1}1' <<<"${1:-}"; }

# wildcard-aware match: cert pattern may be exact or *.example.com
host_matches_pattern() {
  local host="$1" pattern="$2"
  host="$(trim "$host")"
  pattern="$(trim "$pattern")"
  [[ -z "$host" || -z "$pattern" ]] && return 1

  if [[ "$pattern" == \*.* ]]; then
    local suffix="${pattern#*.}"  # example.com
    # host must end with .suffix and have exactly one additional label
    [[ "$host" == *".${suffix}" ]] || return 1
    local left="${host%".${suffix}"}"
    [[ "$left" != *.* ]] || return 1
    return 0
  fi

  [[ "$host" == "$pattern" ]]
}

# Extract SAN DNS names from a cert; fallback to CN if SAN empty
get_cert_names() {
  local crt="$1"
  local sans cn
  sans="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
    | sed -n 's/ *DNS:\([^,]*\),\{0,1\}/\1\n/gp' \
    | sed 's/[[:space:]]//g' \
    | grep -v '^$' || true)"

  if [[ -n "$sans" ]]; then
    printf "%s\n" "$sans"
    return 0
  fi

  cn="$(openssl x509 -in "$crt" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' \
    | head -n 1 || true)"

  [[ -n "$cn" ]] && printf "%s\n" "$cn"
}

# ---------- read ingress ----------
echo "▶ Ingress: ${ns}/${ing}"

# Hosts from rules
mapfile -t ingress_hosts < <(
  kubectl get ingress "$ing" -n "$ns" -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' \
  | sed '/^$/d' | sort -u
)

if [[ "${#ingress_hosts[@]}" -eq 0 ]]; then
  echo "✖ No spec.rules[].host found on ingress ${ns}/${ing}" >&2
  exit 1
fi

echo "• Ingress hosts:"
printf "  - %s\n" "${ingress_hosts[@]}"

# TLS secret names from spec.tls[]
mapfile -t tls_secrets < <(
  kubectl get ingress "$ing" -n "$ns" -o jsonpath='{range .spec.tls[*]}{.secretName}{"\n"}{end}' \
  | sed '/^$/d' | sort -u
)

if [[ "${#tls_secrets[@]}" -eq 0 ]]; then
  echo "✖ No spec.tls[].secretName found on ingress ${ns}/${ing}" >&2
  exit 1
fi

echo "• TLS secrets:"
printf "  - %s\n" "${tls_secrets[@]}"

# Optional: tls.hosts (if present) for display
mapfile -t tls_hosts_declared < <(
  kubectl get ingress "$ing" -n "$ns" -o jsonpath='{range .spec.tls[*]}{range .hosts[*]}{.}{"\n"}{end}{end}' \
  | sed '/^$/d' | sort -u || true
)
if [[ "${#tls_hosts_declared[@]}" -gt 0 ]]; then
  echo "• Ingress spec.tls[].hosts:"
  printf "  - %s\n" "${tls_hosts_declared[@]}"
fi

echo

# ---------- check each secret cert covers each ingress host ----------
fail=0

for sec in "${tls_secrets[@]}"; do
  echo "▶ Secret: ${ns}/${sec}"

  crt_path="${tmpdir}/${sec}.crt"
  if ! kubectl get secret "$sec" -n "$ns" -o jsonpath='{.data.tls\.crt}' >/dev/null 2>&1; then
    echo "  ✖ Secret not found or unreadable" >&2
    fail=1
    echo
    continue
  fi

  b64="$(kubectl get secret "$sec" -n "$ns" -o jsonpath='{.data.tls\.crt}' || true)"
  if [[ -z "$b64" ]]; then
    echo "  ✖ Secret has no data.tls.crt" >&2
    fail=1
    echo
    continue
  fi

  # macOS base64 uses -D, linux uses -d; we already have openssl so use it for decode
  printf "%s" "$b64" | openssl base64 -d -A > "$crt_path" 2>/dev/null || {
    echo "  ✖ Failed to base64-decode tls.crt" >&2
    fail=1
    echo
    continue
  }

  # Basic cert info
  subj="$(openssl x509 -in "$crt_path" -noout -subject 2>/dev/null || true)"
  issr="$(openssl x509 -in "$crt_path" -noout -issuer 2>/dev/null || true)"
  vldt="$(openssl x509 -in "$crt_path" -noout -dates 2>/dev/null || true)"

  echo "  • $subj"
  echo "  • $issr"
  echo "  • $vldt"

  mapfile -t cert_names < <(get_cert_names "$crt_path" | sort -u)

  if [[ "${#cert_names[@]}" -eq 0 ]]; then
    echo "  ✖ Could not extract SAN or CN from certificate" >&2
    fail=1
    echo
    continue
  fi

  echo "  • Names in cert (SAN/CN):"
  printf "    - %s\n" "${cert_names[@]}"

  # Check each ingress host against cert names
  for h in "${ingress_hosts[@]}"; do
    matched=0
    for n in "${cert_names[@]}"; do
      if host_matches_pattern "$h" "$n"; then
        matched=1
        break
      fi
    done

    if [[ "$matched" -eq 1 ]]; then
      echo "  ✅ host covered: $h"
    else
      echo "  ❌ host NOT covered: $h"
      fail=1
    fi
  done

  echo
done

if [[ "$fail" -ne 0 ]]; then
  echo "✖ TLS host/cert mismatch detected for ${ns}/${ing}" >&2
  exit 1
fi

echo "✅ All ingress hosts are covered by the referenced TLS certificate(s)."
