#!/usr/bin/env bash
# shellcheck shell=bash
# Migrate pgAdmin from dynamically-provisioned PVC to named Longhorn volume.
# Copies data from old PVC (pgadmin-pgadmin4) to new PVC (pgadmin-data).
set -euo pipefail

NAMESPACE="cnpg-cluster"
DEPLOYMENT="pgadmin-pgadmin4"
OLD_PVC="pgadmin-pgadmin4"
NEW_PVC="pgadmin-data"
COPY_POD="pgadmin-volume-copy"
ARGOCD_APPS=("pgadmin" "app-data")

ARGOCD_PAUSED=false

cleanup() {
  kubectl delete pod "$COPY_POD" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  if [ "$ARGOCD_PAUSED" = true ]; then
    echo "Resuming ArgoCD auto-sync due to script exit..."
    for app in "${ARGOCD_APPS[@]}"; do
      kubectl patch application "$app" -n argocd --type merge \
        -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

echo "=== pgAdmin Volume Migration ==="
echo ""
echo "This script migrates pgAdmin data from the old dynamically-provisioned"
echo "volume to the new named Longhorn volume (pgadmin-data)."
echo ""

# --- Pre-flight checks ---
echo "Running pre-flight checks..."

if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Deployment $DEPLOYMENT not found in namespace $NAMESPACE."
  exit 1
fi

if ! kubectl get pvc "$OLD_PVC" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Old PVC $OLD_PVC not found in namespace $NAMESPACE."
  exit 1
fi

if ! kubectl get pvc "$NEW_PVC" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: New PVC $NEW_PVC not found in namespace $NAMESPACE."
  echo "Deploy the updated pgadmin chart first (it creates the named PV+PVC)."
  exit 1
fi

old_pv=$(kubectl get pvc "$OLD_PVC" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
echo "  Old PVC: $OLD_PVC → PV: $old_pv"
echo "  New PVC: $NEW_PVC"
echo ""

# --- Confirmation ---
read -rp "Continue with migration? (yes/no) " CONFIRM
if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 1
fi

# --- Pause ArgoCD ---
echo ""
echo "Pausing ArgoCD auto-sync..."
for app in "${ARGOCD_APPS[@]}"; do
  kubectl patch application "$app" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}' 2>/dev/null || true
done
ARGOCD_PAUSED=true

# --- Scale down pgAdmin ---
echo "Scaling down $DEPLOYMENT..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
echo "Waiting for pods to terminate..."
kubectl wait --for=delete pod -l "app.kubernetes.io/name=pgadmin4" \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
echo "pgAdmin stopped."

# --- Copy data ---
echo ""
echo "Spawning temporary copy pod..."
kubectl run "$COPY_POD" -n "$NAMESPACE" \
  --image=busybox:stable \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "copy",
        "image": "busybox:stable",
        "command": ["sleep", "3600"],
        "volumeMounts": [
          {"name": "old-vol", "mountPath": "/old"},
          {"name": "new-vol", "mountPath": "/new"}
        ]
      }],
      "volumes": [
        {"name": "old-vol", "persistentVolumeClaim": {"claimName": "'"$OLD_PVC"'"}},
        {"name": "new-vol", "persistentVolumeClaim": {"claimName": "'"$NEW_PVC"'"}}
      ]
    }
  }'

echo "Waiting for copy pod to be ready..."
kubectl wait --for=condition=Ready pod/"$COPY_POD" -n "$NAMESPACE" --timeout=120s

echo "Copying data from old volume to new volume..."
kubectl exec "$COPY_POD" -n "$NAMESPACE" -- sh -c 'cp -a /old/. /new/'
echo "Data copy complete."

echo "Cleaning up copy pod..."
kubectl delete pod "$COPY_POD" -n "$NAMESPACE" --wait=true

# --- Scale up pgAdmin ---
echo ""
echo "Scaling up $DEPLOYMENT..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1

echo "Waiting for pgAdmin to be ready..."
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
echo "pgAdmin is running."

# --- Resume ArgoCD ---
echo ""
echo "Resuming ArgoCD auto-sync..."
for app in "${ARGOCD_APPS[@]}"; do
  kubectl patch application "$app" -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' 2>/dev/null || true
done
ARGOCD_PAUSED=false

# --- Old volume cleanup ---
echo ""
echo "Migration complete. pgAdmin is now using the named volume (pgadmin-data)."
echo ""
echo "Old volume cleanup (optional):"
echo "  Old PVC: $OLD_PVC"
echo "  Old PV:  $old_pv"
echo ""
read -rp "Delete old PVC, PV, and Longhorn volume? (yes/no) " CLEANUP
if [ "$CLEANUP" = "yes" ] || [ "$CLEANUP" = "y" ]; then
  echo "Deleting old PVC..."
  kubectl delete pvc "$OLD_PVC" -n "$NAMESPACE" --ignore-not-found
  echo "Deleting old PV..."
  kubectl delete pv "$old_pv" --ignore-not-found
  echo "Deleting old Longhorn volume..."
  kubectl delete volumes.longhorn.io "$old_pv" -n longhorn-system --ignore-not-found
  echo "Old volume cleaned up."
else
  echo "Skipped. Clean up manually when ready:"
  echo "  kubectl delete pvc $OLD_PVC -n $NAMESPACE"
  echo "  kubectl delete pv $old_pv"
  echo "  kubectl delete volumes.longhorn.io $old_pv -n longhorn-system"
fi

echo ""
echo "Done."
