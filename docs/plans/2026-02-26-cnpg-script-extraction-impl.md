# CNPG Script Extraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract ~280 lines of inline bash from `taskfiles/database.yaml` into standalone scripts with a shared library, preserving identical behavior.

**Architecture:** Three files in `scripts/`: a shared library (`cnpg-lib.sh`) sourced by two executable scripts (`cnpg-restore.sh`, `cnpg-restore-verify.sh`). The Taskfile becomes a thin dispatch layer. Manifest generation uses the "base + pipe" pattern — the library function outputs the base recovery manifest, callers pipe through additional yq transforms as needed.

**Tech Stack:** Bash, Taskfile v3, Helm, yq (mikefarah/yq v4), kubectl, kubectl-cnpg plugin

**Design doc:** `docs/plans/2026-02-26-cnpg-script-extraction-design.md`

---

### Task 1: Create `scripts/cnpg-lib.sh`

The shared library sourced by both restore scripts. Contains four functions that eliminate all duplicated logic.

**Files:**
- Create: `scripts/cnpg-lib.sh`

**Step 1: Create the library file**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Shared functions for CNPG restore scripts.
# Source this file — do not execute it directly.
#
# Expects caller to set before sourcing:
#   NAMESPACE    — Kubernetes namespace (e.g., "cnpg-cluster")
#   CLUSTER_NAME — CNPG cluster name (e.g., "cnpg-cluster")
#   CHART_PATH   — path to the Helm chart (e.g., "cluster/apps/cnpg-cluster")

cnpg_get_db_name() {
  yq '.initdb.database' "$CHART_PATH/values.yaml"
}

# cnpg_preflight [pitr_target]
# Validates backups exist and PITR target is within recovery window.
# Sets globals: BACKUP_COUNT, LATEST_BACKUP, FIRST_RECOVERABLE
# Exits 1 on fatal errors (no backups, PITR out of range).
cnpg_preflight() {
  local pitr_target="${1:-}"

  echo "Running pre-flight checks..."

  COMPLETED_BACKUPS=$(kubectl get backups.postgresql.cnpg.io -n "$NAMESPACE" \
    -o jsonpath='{.items[?(@.status.phase=="completed")].metadata.name}')
  if [ -z "$COMPLETED_BACKUPS" ]; then
    echo "ERROR: No completed backups found. Cannot restore."
    exit 1
  fi
  BACKUP_COUNT=$(echo "$COMPLETED_BACKUPS" | wc -w | tr -d ' ')
  LATEST_BACKUP=$(echo "$COMPLETED_BACKUPS" | tr ' ' '\n' | tail -1)
  echo "  Backups: $BACKUP_COUNT completed"
  echo "  Latest: $LATEST_BACKUP"

  local cluster_phase
  cluster_phase=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
  if [ "$cluster_phase" != "Cluster in healthy state" ]; then
    echo "  WARNING: Cluster is not healthy (phase: $cluster_phase)"
  fi

  FIRST_RECOVERABLE=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null || echo "")
  if [ -n "$FIRST_RECOVERABLE" ]; then
    echo "  Recovery window: $FIRST_RECOVERABLE → now"
  else
    echo "  WARNING: No recovery window information. PITR may not work."
  fi

  if [ -n "$pitr_target" ]; then
    echo "  PITR target: $pitr_target"
    if [ -n "$FIRST_RECOVERABLE" ] && [[ "$pitr_target" < "$FIRST_RECOVERABLE" ]]; then
      echo "ERROR: PITR target ($pitr_target) is before first recoverability point ($FIRST_RECOVERABLE)."
      exit 1
    fi
  fi
}

# cnpg_generate_recovery_manifest [pitr_target]
# Outputs base recovery Cluster YAML to stdout.
# Caller can pipe through additional yq transforms.
# Exits 1 if helm template or yq fails.
cnpg_generate_recovery_manifest() {
  local pitr_target="${1:-}"

  local yq_expr='select(.kind == "Cluster")
    | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
    | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup", "serverName": "cnpg-cluster"}}}]
    | del(.spec.plugins)'

  if [ -n "$pitr_target" ]; then
    yq_expr="$yq_expr | .spec.bootstrap.recovery.recoveryTarget.targetTime = \"$pitr_target\""
  fi

  local manifest
  manifest=$(helm template cnpg-cluster "$CHART_PATH" --namespace "$NAMESPACE" | yq "$yq_expr")
  if [ -z "$manifest" ]; then
    echo "ERROR: Failed to generate recovery manifest." >&2
    exit 1
  fi
  echo "$manifest"
}

# cnpg_wait_for_healthy cluster_name timeout_seconds
# Polls until the cluster has at least one Running pod and reports healthy.
# Exits 1 on timeout.
cnpg_wait_for_healthy() {
  local cluster="$1"
  local timeout="$2"
  local start_wait
  start_wait=$(date +%s)

  until [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$cluster" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "1" ]; do
    if [ $(($(date +%s) - start_wait)) -ge "$timeout" ]; then
      echo "ERROR: Timed out waiting for pods."
      echo "Debug: kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$cluster"
      exit 1
    fi
    sleep 5
  done
  echo "At least one pod is running."

  until [ "$(kubectl get cluster "$cluster" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ]; do
    if [ $(($(date +%s) - start_wait)) -ge "$timeout" ]; then
      echo "ERROR: Timed out waiting for healthy state."
      echo "Debug: kubectl cnpg status $cluster -n $NAMESPACE"
      exit 1
    fi
    sleep 5
  done
  echo "Cluster is healthy."
}
```

**Step 2: Verify shellcheck passes**

Run: `shellcheck scripts/cnpg-lib.sh`

Expected: No warnings or errors.

**Step 3: Commit**

```bash
git add scripts/cnpg-lib.sh
git commit -m "refactor: add shared CNPG restore library

Extracts pre-flight checks, manifest generation, and health polling
into reusable functions sourced by restore scripts."
```

---

### Task 2: Create `scripts/cnpg-restore.sh`

Production restore script. Uses the shared library for pre-flight, manifest generation, and health polling. Script body is orchestration only.

**Files:**
- Create: `scripts/cnpg-restore.sh`
- Read: `taskfiles/database.yaml:56-219` (current inline restore task — extract logic from here)

**Step 1: Create the restore script**

```bash
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
kubectl delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --wait=true --timeout=120s

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
kubectl cnpg psql "$CLUSTER_NAME" -n "$NAMESPACE" -- -d "$DB_NAME" -c "SELECT 1" > /dev/null 2>&1
echo "Database '$DB_NAME' is accessible."

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
```

**Step 2: Make executable and verify shellcheck**

Run: `chmod +x scripts/cnpg-restore.sh && shellcheck scripts/cnpg-restore.sh`

Expected: No warnings or errors.

**Step 3: Commit**

```bash
git add scripts/cnpg-restore.sh
git commit -m "refactor: extract production restore to scripts/cnpg-restore.sh

Same behavior as the inline task. Uses cnpg-lib.sh for pre-flight,
manifest generation, and health polling."
```

---

### Task 3: Create `scripts/cnpg-restore-verify.sh`

Non-destructive DR test script. Same library functions plus the cleanup trap and temp cluster yq transforms.

**Files:**
- Create: `scripts/cnpg-restore-verify.sh`
- Read: `taskfiles/database.yaml:221-347` (current inline restore-verify task — extract logic from here)

**Step 1: Create the verify script**

```bash
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
```

**Step 2: Make executable and verify shellcheck**

Run: `chmod +x scripts/cnpg-restore-verify.sh && shellcheck scripts/cnpg-restore-verify.sh`

Expected: No warnings or errors.

**Step 3: Commit**

```bash
git add scripts/cnpg-restore-verify.sh
git commit -m "refactor: extract DR test to scripts/cnpg-restore-verify.sh

Same behavior as the inline task. Uses cnpg-lib.sh for shared logic.
Temp cluster transforms (name, instances) applied via yq pipe."
```

---

### Task 4: Replace inline tasks in `database.yaml`

Replace the two ~150-line inline blocks with one-line script calls. Keep simple tasks unchanged.

**Files:**
- Modify: `taskfiles/database.yaml:56-347` (replace `restore` and `restore-verify` task bodies)

**Step 1: Replace the restore task**

In `taskfiles/database.yaml`, replace the entire `restore` task (lines 56-219) with:

```yaml
  restore:
    desc: "Restore CNPG cluster from backup (usage: task db:restore [-- \"PITR-timestamp\"])"
    deps: [_require-cnpg-plugin, _require-yq, _require-helm]
    interactive: true
    cmds:
      - scripts/cnpg-restore.sh {{.CLI_ARGS}}
```

**Step 2: Replace the restore-verify task**

Replace the entire `restore-verify` task (lines 221-347) with:

```yaml
  restore-verify:
    desc: "Non-destructive DR test: restore to temp cluster, validate, cleanup (usage: task db:restore-verify [-- \"PITR-timestamp\"])"
    deps: [_require-cnpg-plugin, _require-yq, _require-helm]
    interactive: true
    cmds:
      - scripts/cnpg-restore-verify.sh {{.CLI_ARGS}}
```

**Step 3: Verify Taskfile parses correctly**

Run: `task --list`

Expected: `db:restore` and `db:restore-verify` appear in the list alongside `db:status`, `db:backup`, `db:backups`, `db:psql`.

**Step 4: Commit**

```bash
git add taskfiles/database.yaml
git commit -m "refactor: replace inline restore scripts with external script calls

database.yaml drops from 347 to ~70 lines. Restore logic now lives
in scripts/cnpg-restore.sh and scripts/cnpg-restore-verify.sh."
```

---

### Task 5: Run shellcheck on all scripts and verify task dispatch

Final validation that everything is wired up correctly.

**Files:**
- Read: `scripts/cnpg-lib.sh`, `scripts/cnpg-restore.sh`, `scripts/cnpg-restore-verify.sh`
- Read: `taskfiles/database.yaml`

**Step 1: Shellcheck all scripts**

Run: `shellcheck scripts/cnpg-lib.sh scripts/cnpg-restore.sh scripts/cnpg-restore-verify.sh`

Expected: No warnings or errors.

**Step 2: Verify Taskfile lists all tasks**

Run: `task --list`

Expected output includes:
```
* db:backup:           Trigger an on-demand backup
* db:backups:          List all backups with status
* db:psql:             Open interactive psql shell on the primary
* db:restore:          Restore CNPG cluster from backup (usage: task db:restore [-- "PITR-timestamp"])
* db:restore-verify:   Non-destructive DR test: restore to temp cluster, validate, cleanup (usage: task db:restore-verify [-- "PITR-timestamp"])
* db:status:           Show CNPG cluster health and backup status
```

**Step 3: Verify script is executable and sources correctly**

Run: `bash -n scripts/cnpg-restore.sh && bash -n scripts/cnpg-restore-verify.sh && echo "Syntax OK"`

Expected: `Syntax OK` (confirms no bash syntax errors).

**Step 4: Final line count comparison**

Run: `wc -l taskfiles/database.yaml scripts/cnpg-lib.sh scripts/cnpg-restore.sh scripts/cnpg-restore-verify.sh`

Expected: `database.yaml` is ~70 lines. Total across all files is similar to the original 347, but now properly structured and lintable.
