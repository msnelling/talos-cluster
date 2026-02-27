#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=cnpg-lib.sh
source "$SCRIPT_DIR/cnpg-lib.sh"

PITR_TARGET="${1:-}"
NAMESPACE="cnpg-cluster"
CLUSTER_NAME="cnpg-cluster"
CHART_PATH="cluster/apps/cnpg-cluster"

DB_NAME=$(cnpg_get_db_name)

echo "=== CNPG Cluster Restore ==="
echo ""

# --- Pre-flight ---
cnpg_preflight "$PITR_TARGET"

echo ""
echo "Available backups:"
kubectl get backups.postgresql.cnpg.io -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp

# --- Generate recovery manifest (before any destructive action) ---
echo ""
echo "Generating recovery manifest from Helm chart..."
RECOVERY_MANIFEST=$(cnpg_generate_recovery_manifest "$PITR_TARGET")
echo "Recovery manifest generated successfully."

# --- Confirmation ---
echo ""
if [ -n "$PITR_TARGET" ]; then
  echo "Ready to restore to point-in-time: $PITR_TARGET"
else
  echo "Ready to restore from latest backup."
fi
read -rp "This will DELETE the production cluster and restore from backup. Continue? (yes/no) " CONFIRM
if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 1
fi

# --- Pause ArgoCD ---
echo ""
echo "Pausing ArgoCD auto-sync..."
kubectl patch application cnpg-cluster -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch application app-data -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# --- Delete Cluster CR ---
TIMEOUT=600
START_WAIT=$(date +%s)

echo "Deleting Cluster CR (pods will terminate)..."
kubectl delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --wait=true --timeout=120s --ignore-not-found

echo "Waiting for all pods to terminate..."
until [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq "0" ]; do
  if [ $(($(date +%s) - START_WAIT)) -ge $TIMEOUT ]; then
    echo "ERROR: Timed out waiting for pods to terminate. ArgoCD remains paused."
    echo "Debug: kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME"
    exit 1
  fi
  sleep 3
done
echo "All pods terminated."

# --- Apply recovery manifest ---
echo ""
echo "Applying recovery manifest..."
echo "$RECOVERY_MANIFEST" | kubectl apply -f -

# --- Wait for healthy ---
echo "Waiting for cluster to become healthy..."
cnpg_wait_for_healthy "$CLUSTER_NAME" $TIMEOUT

# --- Validate ---
echo "Validating database connectivity..."
cnpg_validate_db "$CLUSTER_NAME" "$DB_NAME"

# --- Resume ArgoCD ---
echo ""
echo "Resuming ArgoCD auto-sync..."
kubectl patch application cnpg-cluster -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl patch application app-data -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# --- Final status ---
echo ""
kubectl cnpg status "$CLUSTER_NAME" -n "$NAMESPACE"
echo ""
echo "Restore complete. ArgoCD will re-sync the normal Cluster template."
echo "(Safe: CNPG will not re-init an existing data directory)"
