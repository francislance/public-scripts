kubectl get crd -o json \
  | jq -r '
    .items[]
    | select(
        .spec.versions[]
        | .subresources? .status?
      )
    | .metadata.name
  '


for crd in $(kubectl get crd -o json \
  | jq -r '.items[]
    | select(.spec.versions[]? .subresources? .status?)
    | .spec.names.plural+"."+.spec.group'); do
  echo "=== $crd ==="
  kubectl get "$crd" -A --no-headers 2>/dev/null | wc -l
done


crd="virtualservices.networking.istio.io"

kubectl get "$crd" -A -o json \
  | jq -r '
    .items[]
    | {
        ns: .metadata.namespace,
        name: .metadata.name,
        status_size: (.status | tostring | length)
      }
  ' | sort -k3 -nr | head
