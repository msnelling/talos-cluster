#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=cnpg-lib.sh
source "$SCRIPT_DIR/cnpg-lib.sh"

PITR_TARGET="${1:-}"
NAMESPACE="cnpg-cluster"
CLUSTER_NAME="cnpg-cluster"
TEMP_CLUSTER="cnpg-cluster-restore-test"
CHART_PATH="cluster/apps/cnpg-cluster"
TIMEOUT=600

DB_NAME=$(cnpg_get_db_name)

cleanup() {
  echo ""
  echo "Cleaning up temporary cluster..."
  kubectl delete cluster "$TEMP_CLUSTER" -n "$NAMESPACE" --ignore-not-found --timeout=60s 2>/dev/null || true
  # Capture PV names before deleting PVCs, then delete PVCs, PVs, and Longhorn volumes
  # (Longhorn Retain policy leaves PVs and volumes behind after PVC deletion)
  local pv_names
  pv_names=$(kubectl get pvc -n "$NAMESPACE" -l "cnpg.io/cluster=$TEMP_CLUSTER" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
  kubectl delete pvc -n "$NAMESPACE" -l "cnpg.io/cluster=$TEMP_CLUSTER" --ignore-not-found 2>/dev/null || true
  for pv in $pv_names; do
    kubectl delete pv "$pv" --ignore-not-found 2>/dev/null || true
    kubectl delete volumes.longhorn.io "$pv" -n longhorn-system --ignore-not-found 2>/dev/null || true
  done
  echo "Cleanup complete. Production cluster was not affected."
}
trap cleanup EXIT

echo "=== CNPG Restore Verification (Non-destructive) ==="
echo ""

# --- Pre-flight ---
cnpg_preflight "$PITR_TARGET"

# --- Generate temp cluster manifest ---
echo ""
echo "Generating temporary cluster manifest..."
MANIFEST=$(cnpg_generate_recovery_manifest "$PITR_TARGET" \
  | yq '.metadata.name = "'"$TEMP_CLUSTER"'" | .spec.instances = 1')
echo "Manifest generated successfully."

# --- Apply temp cluster ---
echo "Applying temporary cluster (1 instance)..."
echo "$MANIFEST" | kubectl apply -f -

# --- Wait for healthy ---
echo "Waiting for temporary cluster to become healthy (timeout: 10 min)..."
START_WAIT=$(date +%s)
cnpg_wait_for_healthy "$TEMP_CLUSTER" $TIMEOUT
RECOVERY_TIME=$(($(date +%s) - START_WAIT))
MINUTES=$((RECOVERY_TIME / 60))
SECS=$((RECOVERY_TIME % 60))

# --- Validate ---
echo "Validating database connectivity..."
if kubectl cnpg psql "$TEMP_CLUSTER" -n "$NAMESPACE" -- -d "$DB_NAME" -c "SELECT 1" > /dev/null 2>&1; then
  echo "Database '$DB_NAME' is accessible."
  echo ""
  echo "Restore test PASSED. Recovery took ${MINUTES}m ${SECS}s."
else
  echo ""
  echo "Restore test FAILED: Could not connect to database '$DB_NAME'."
  exit 1
fi

# Cleanup happens via EXIT trap
