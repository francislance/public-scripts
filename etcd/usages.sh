#!/bin/bash

# --- Configuration ---
export ETCDCTL_API=3
# Set your etcd endpoints and authentication details here (if needed)
# export ETCDCTL_ENDPOINTS="https://etcd-master-1:2379,https://etcd-master-2:2379"
# export ETCDCTL_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
# export ETCDCTL_CERT="/etc/kubernetes/pki/etcd/server.crt"
# export ETCDCTL_KEY="/etc/kubernetes/pki/etcd/server.key"
# ---------------------

# Function to calculate the total size for a given registry path
calculate_size() {
    local prefix=$1
    local total_bytes=0
    echo "Calculating size for: $prefix..."

    # Iterate over all keys with the given prefix
    # Note: This operation can be slow and put load on etcd in large clusters
    for key in $(etcdctl get "$prefix" --prefix --keys-only); do
        size=$(etcdctl get "$key" --print-value-only | wc -c)
        total_bytes=$((total_bytes + size))
    done
    echo "Done."
    echo $total_bytes
}

echo "Starting etcd resource size calculation..."

# Calculate sizes for specific resources
PODS_SIZE=$(calculate_size "/registry/pods/")
RS_SIZE=$(calculate_size "/registry/replicasets/")
CM_SIZE=$(calculate_size "/registry/configmaps/")
SECRETS_SIZE=$(calculate_size "/registry/secrets/")
CRDS_SIZE=$(calculate_size "/registry/apiextensions.k8s.io/customresourcedefinitions/") # CRD definitions themselves
# For CRD *instances*, it's more complex as the path depends on the CRD's group/version/kind
# You would need to add specific lines for the custom resources you have, e.g.:
# MYCRD_SIZE=$(calculate_size "/registry/mygroup.com")

echo ""
echo "--- Etcd Storage Usage Summary (Current Data Value Size Only) ---"
printf "%-25s | %-15s | %-15s\n" "RESOURCE TYPE" "TOTAL BYTES" "APPROX. KB"
printf "%-25s + %-15s + %-15s\n" "-------------------------" "---------------" "---------------"
printf "%-25s | %-15s | %-15s\n" "Pods" $PODS_SIZE $((PODS_SIZE / 1024))
printf "%-25s | %-15s | %-15s\n" "ReplicaSets" $RS_SIZE $((RS_SIZE / 1024))
printf "%-25s | %-15s | %-15s\n" "ConfigMaps" $CM_SIZE $((CM_SIZE / 1024))
printf "%-25s | %-15s | %-15s\n" "Secrets" $SECRETS_SIZE $((SECRETS_SIZE / 1024))
printf "%-25s | %-15s | %-15s\n" "CRDs (Definitions)" $CRDS_SIZE $((CRDS_SIZE / 1024))
# Add custom resource instances here if calculated

# A more accurate measure of total etcd usage involves Prometheus metrics like etcd_mvcc_db_total_size_in_bytes,
# as this script doesn't measure historical MVCC data or overall database overhead.
