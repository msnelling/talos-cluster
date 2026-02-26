# Restore Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the fragile 3-step CNPG restore flow with two robust tasks: `db:restore` (production restore with pre-flight checks) and `db:restore-verify` (non-destructive DR test).

**Architecture:** Generate recovery manifests dynamically from the Helm chart via `helm template` + `yq`, eliminating manifest drift. Pre-flight checks use structured JSON from `kubectl get`. `db:restore-verify` creates a temporary single-instance cluster for validation with automatic cleanup.

**Tech Stack:** Taskfile v3, Helm, yq (mikefarah/yq v4), kubectl, kubectl-cnpg plugin

**Design doc:** `docs/plans/2026-02-26-restore-hardening-design.md`

---

### Task 1: Validate the helm template + yq pipeline

Verify the manifest generation approach works before writing Taskfile code.

**Files:**
- Read: `cluster/apps/cnpg-cluster/templates/cluster.yaml`
- Read: `cluster/apps/cnpg-cluster/values.yaml`

**Step 1: Test base rendering**

Run:
```bash
helm template cnpg-cluster cluster/apps/cnpg-cluster --namespace cnpg-cluster \
  | yq 'select(.kind == "Cluster")'
```

Expected output — a Cluster YAML with:
- `metadata.name: cnpg-cluster`
- `metadata.namespace: cnpg-cluster`
- `spec.instances: 3`
- `spec.storage.size: 10Gi`
- `spec.storage.storageClass: longhorn-single-replica`
- `spec.bootstrap.initdb` present
- `spec.plugins` present (WAL archiving config)

**Step 2: Test full recovery transformation**

Run:
```bash
helm template cnpg-cluster cluster/apps/cnpg-cluster --namespace cnpg-cluster | yq '
  select(.kind == "Cluster")
  | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
  | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]
  | del(.spec.plugins)'
```

Expected:
- `spec.bootstrap.recovery.source: cnpg-cluster-backup` (no `initdb`)
- `spec.externalClusters[0].plugin.name: barman-cloud.cloudnative-pg.io`
- No `spec.plugins` section
- All other fields (instances, storage, resources, affinity) unchanged

**Step 3: Test temp cluster + PITR variant**

Run:
```bash
helm template cnpg-cluster cluster/apps/cnpg-cluster --namespace cnpg-cluster | yq '
  select(.kind == "Cluster")
  | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
  | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]
  | del(.spec.plugins)
  | .metadata.name = "cnpg-cluster-restore-test"
  | .spec.instances = 1
  | .spec.bootstrap.recovery.recoveryTarget.targetTime = "2026-02-26T14:30:00+00:00"'
```

Expected:
- `metadata.name: cnpg-cluster-restore-test`
- `spec.instances: 1`
- `spec.bootstrap.recovery.recoveryTarget.targetTime: "2026-02-26T14:30:00+00:00"`

---

### Task 2: Rewrite database.yaml with new restore tasks

**Files:**
- Modify: `taskfiles/database.yaml` — replace `restore-prep`/`restore-apply`/`restore-finish` with `restore` + `restore-verify`, add precondition helpers

**Step 1: Add precondition helpers**

Add these after `_require-cnpg-plugin` in `taskfiles/database.yaml`:

```yaml
  _require-yq:
    internal: true
    preconditions:
      - sh: command -v yq
        msg: |
          yq is required. Install with:
            brew install yq

  _require-helm:
    internal: true
    preconditions:
      - sh: command -v helm
        msg: |
          helm is required. Install with:
            brew install helm
```

**Step 2: Write the `restore` task**

Replace `restore-prep`, `restore-apply`, and `restore-finish` with this single task:

```yaml
  restore:
    desc: "Restore CNPG cluster from backup (usage: task db:restore [-- \"PITR-timestamp\"])"
    deps: [_require-cnpg-plugin, _require-yq, _require-helm]
    interactive: true
    cmds:
      - |
        set -euo pipefail

        PITR_TARGET="{{.CLI_ARGS}}"
        NAMESPACE="cnpg-cluster"
        CLUSTER_NAME="cnpg-cluster"
        CHART_PATH="cluster/apps/cnpg-cluster"
        DB_NAME=$(yq '.initdb.database' "$CHART_PATH/values.yaml")

        echo "=== CNPG Cluster Restore ==="
        echo ""

        # --- Pre-flight checks ---
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

        CLUSTER_PHASE=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        if [ "$CLUSTER_PHASE" != "Cluster in healthy state" ]; then
          echo "  WARNING: Cluster is not healthy (phase: $CLUSTER_PHASE)"
        fi

        FIRST_RECOVERABLE=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
          -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null || echo "")
        if [ -n "$FIRST_RECOVERABLE" ]; then
          echo "  Recovery window: $FIRST_RECOVERABLE → now"
        else
          echo "  WARNING: No recovery window information. PITR may not work."
        fi

        if [ -n "$PITR_TARGET" ]; then
          echo "  PITR target: $PITR_TARGET"
          if [ -n "$FIRST_RECOVERABLE" ] && [[ "$PITR_TARGET" < "$FIRST_RECOVERABLE" ]]; then
            echo "ERROR: PITR target ($PITR_TARGET) is before first recoverability point ($FIRST_RECOVERABLE)."
            exit 1
          fi
        fi

        echo ""
        echo "Available backups:"
        kubectl get backups.postgresql.cnpg.io -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp

        # --- Generate recovery manifest (before any destructive action) ---
        echo ""
        echo "Generating recovery manifest from Helm chart..."

        YQ_EXPR='select(.kind == "Cluster")
          | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
          | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]
          | del(.spec.plugins)'

        if [ -n "$PITR_TARGET" ]; then
          YQ_EXPR="$YQ_EXPR | .spec.bootstrap.recovery.recoveryTarget.targetTime = \"$PITR_TARGET\""
        fi

        RECOVERY_MANIFEST=$(helm template cnpg-cluster "$CHART_PATH" --namespace "$NAMESPACE" | yq "$YQ_EXPR")
        if [ -z "$RECOVERY_MANIFEST" ]; then
          echo "ERROR: Failed to generate recovery manifest."
          exit 1
        fi
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
        echo "Deleting Cluster CR (pods will terminate)..."
        kubectl delete cluster "$CLUSTER_NAME" -n "$NAMESPACE" --wait=true --timeout=120s

        echo "Waiting for all pods to terminate..."
        until [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq "0" ]; do
          sleep 3
        done
        echo "All pods terminated."

        # --- Apply recovery manifest ---
        echo ""
        echo "Applying recovery manifest..."
        echo "$RECOVERY_MANIFEST" | kubectl apply -f -

        # --- Wait for healthy (10 min timeout) ---
        echo "Waiting for cluster to become healthy (timeout: 10 min)..."
        TIMEOUT=600
        START_WAIT=$SECONDS

        until [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$CLUSTER_NAME" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "1" ]; do
          if [ $((SECONDS - START_WAIT)) -ge $TIMEOUT ]; then
            echo "ERROR: Timed out waiting for pods. ArgoCD remains paused."
            echo "Debug: kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER_NAME"
            echo "Resume manually after resolving."
            exit 1
          fi
          sleep 5
        done
        echo "At least one pod is running."

        until [ "$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')" = "Cluster in healthy state" ]; do
          if [ $((SECONDS - START_WAIT)) -ge $TIMEOUT ]; then
            echo "ERROR: Timed out waiting for healthy state. ArgoCD remains paused."
            echo "Debug: kubectl cnpg status $CLUSTER_NAME -n $NAMESPACE"
            exit 1
          fi
          sleep 5
        done
        echo "Cluster is healthy."

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

**Step 3: Write the `restore-verify` task**

Add after the `restore` task:

```yaml
  restore-verify:
    desc: "Non-destructive DR test: restore to temp cluster, validate, cleanup (usage: task db:restore-verify [-- \"PITR-timestamp\"])"
    deps: [_require-cnpg-plugin, _require-yq, _require-helm]
    cmds:
      - |
        set -euo pipefail

        PITR_TARGET="{{.CLI_ARGS}}"
        NAMESPACE="cnpg-cluster"
        CLUSTER_NAME="cnpg-cluster"
        TEMP_CLUSTER="cnpg-cluster-restore-test"
        CHART_PATH="cluster/apps/cnpg-cluster"
        DB_NAME=$(yq '.initdb.database' "$CHART_PATH/values.yaml")
        TIMEOUT=600

        cleanup() {
          echo ""
          echo "Cleaning up temporary cluster..."
          kubectl delete cluster "$TEMP_CLUSTER" -n "$NAMESPACE" --ignore-not-found --timeout=60s 2>/dev/null || true
          kubectl delete pvc -n "$NAMESPACE" -l "cnpg.io/cluster=$TEMP_CLUSTER" --ignore-not-found 2>/dev/null || true
          echo "Cleanup complete. Production cluster was not affected."
        }
        trap cleanup EXIT

        echo "=== CNPG Restore Verification (Non-destructive) ==="
        echo ""

        # --- Pre-flight checks ---
        echo "Running pre-flight checks..."

        COMPLETED_BACKUPS=$(kubectl get backups.postgresql.cnpg.io -n "$NAMESPACE" \
          -o jsonpath='{.items[?(@.status.phase=="completed")].metadata.name}')
        if [ -z "$COMPLETED_BACKUPS" ]; then
          echo "ERROR: No completed backups found."
          exit 1
        fi
        BACKUP_COUNT=$(echo "$COMPLETED_BACKUPS" | wc -w | tr -d ' ')
        LATEST_BACKUP=$(echo "$COMPLETED_BACKUPS" | tr ' ' '\n' | tail -1)
        echo "  Backups: $BACKUP_COUNT completed"
        echo "  Latest: $LATEST_BACKUP"

        FIRST_RECOVERABLE=$(kubectl get cluster "$CLUSTER_NAME" -n "$NAMESPACE" \
          -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null || echo "")
        if [ -n "$FIRST_RECOVERABLE" ]; then
          echo "  Recovery window: $FIRST_RECOVERABLE → now"
        fi

        if [ -n "$PITR_TARGET" ]; then
          echo "  PITR target: $PITR_TARGET"
          if [ -n "$FIRST_RECOVERABLE" ] && [[ "$PITR_TARGET" < "$FIRST_RECOVERABLE" ]]; then
            echo "ERROR: PITR target is before first recoverability point."
            exit 1
          fi
        fi

        # --- Generate temp cluster manifest ---
        echo ""
        echo "Generating temporary cluster manifest..."

        YQ_EXPR='select(.kind == "Cluster")
          | .spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}
          | .spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]
          | del(.spec.plugins)
          | .metadata.name = "cnpg-cluster-restore-test"
          | .spec.instances = 1'

        if [ -n "$PITR_TARGET" ]; then
          YQ_EXPR="$YQ_EXPR | .spec.bootstrap.recovery.recoveryTarget.targetTime = \"$PITR_TARGET\""
        fi

        MANIFEST=$(helm template cnpg-cluster "$CHART_PATH" --namespace "$NAMESPACE" | yq "$YQ_EXPR")
        if [ -z "$MANIFEST" ]; then
          echo "ERROR: Failed to generate manifest."
          exit 1
        fi

        # --- Apply temp cluster ---
        echo "Applying temporary cluster (1 instance)..."
        echo "$MANIFEST" | kubectl apply -f -

        # --- Wait for healthy ---
        echo "Waiting for temporary cluster to become healthy (timeout: 10 min)..."
        START_WAIT=$SECONDS

        while [ "$(kubectl get pods -n "$NAMESPACE" -l "cnpg.io/cluster=$TEMP_CLUSTER" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -lt "1" ]; do
          if [ $((SECONDS - START_WAIT)) -ge $TIMEOUT ]; then
            echo "FAILED: Timed out waiting for pod."
            exit 1
          fi
          sleep 5
        done
        echo "Pod is running."

        while [ "$(kubectl get cluster "$TEMP_CLUSTER" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Cluster in healthy state" ]; do
          if [ $((SECONDS - START_WAIT)) -ge $TIMEOUT ]; then
            echo "FAILED: Timed out waiting for healthy state."
            exit 1
          fi
          sleep 5
        done

        RECOVERY_TIME=$((SECONDS - START_WAIT))
        MINUTES=$((RECOVERY_TIME / 60))
        SECS=$((RECOVERY_TIME % 60))
        echo "Temporary cluster is healthy."

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

**Step 4: Verify syntax**

Run: `task --list`

Expected: `db:restore` and `db:restore-verify` appear. `restore-prep`, `restore-apply`, `restore-finish` do not.

**Step 5: Commit**

```bash
git add taskfiles/database.yaml
git commit -m "feat: replace 3-step restore with db:restore and db:restore-verify

Pre-flight checks validate backups before any destructive action.
Recovery manifest generated from helm template + yq (no drift).
db:restore-verify creates a temp cluster for non-destructive DR testing."
```

---

### Task 3: Delete cluster-restore.yaml and fix backup timestamp

**Files:**
- Delete: `cluster/recovery/cluster-restore.yaml`
- Modify: `taskfiles/database.yaml:22-26` (backup task timestamp)

**Step 1: Delete cluster-restore.yaml**

Run: `git rm cluster/recovery/cluster-restore.yaml`

**Step 2: Fix backup timestamp format**

In `taskfiles/database.yaml`, in the `backup` task, change:
```yaml
        export TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        envsubst < cluster/recovery/backup.yaml | kubectl apply -f -
        echo "Backup cnpg-cluster-on-demand-${TIMESTAMP} triggered."
```
to:
```yaml
        export TIMESTAMP=$(date +%Y%m%d%H%M%S)
        envsubst < cluster/recovery/backup.yaml | kubectl apply -f -
        echo "Backup cnpg-cluster-on-demand-${TIMESTAMP} triggered."
```

This aligns on-demand backup naming (`20260226154007`) with CNPG's scheduled backup naming (`20260226000000`) — no dash separator.

**Step 3: Commit**

```bash
git add cluster/recovery/cluster-restore.yaml taskfiles/database.yaml
git commit -m "fix: delete drifting cluster-restore.yaml, align backup timestamp

cluster-restore.yaml replaced by helm template + yq in db:restore.
On-demand backup timestamp format now matches CNPG scheduled naming."
```

---

### Task 4: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:57-64` (Taskfile Structure section)
- Modify: `CLAUDE.md:198` (CNPG gotcha)

**Step 1: Add database tasks to the Commands section**

After the "Utilities" section (line 55) and before "Taskfile Structure" (line 57), add:

```markdown
### Database (CNPG PostgreSQL)
```bash
task db:status          # Show cluster health and backup status
task db:backup          # Trigger an on-demand backup
task db:backups         # List all backups with status
task db:psql            # Open interactive psql shell on the primary
task db:restore         # Full restore: pre-flight → delete → recover → resume ArgoCD
                        # Usage: task db:restore [-- "2026-02-26T14:30:00+00:00"]
task db:restore-verify  # Non-destructive DR test: restore to temp cluster, validate, cleanup
                        # Usage: task db:restore-verify [-- "2026-02-26T14:30:00+00:00"]
```

`db:restore` runs pre-flight checks (backup exists, WAL health, PITR validation), generates the recovery manifest from the Helm chart via `helm template` + `yq`, then performs the restore. On timeout, ArgoCD remains paused for manual investigation.

`db:restore-verify` restores to a temporary single-instance cluster, validates database connectivity, reports timing, and cleans up automatically. Production cluster is never touched.
```

**Step 2: Add database.yaml to the Taskfile Structure list**

In the Taskfile Structure section (~line 63), add:
```
- `taskfiles/database.yaml` -- CNPG PostgreSQL operations (status, backup, restore, psql)
```

**Step 3: Update CNPG gotcha**

Replace the existing CNPG gotcha (line 198) to remove the reference to `cluster/recovery/` templates:

From:
```
**CNPG backups use the Barman Cloud Plugin (not deprecated in-tree barmanObjectStore).** Plugin runs as sidecar injected by barman-cloud-plugin chart in cnpg-system. Config lives in ObjectStore CR, referenced by Cluster via `spec.plugins`. Recovery templates in `cluster/recovery/` reference the ObjectStore CR by name rather than inlining S3 config.
```

To:
```
**CNPG backups use the Barman Cloud Plugin (not deprecated in-tree barmanObjectStore).** Plugin runs as sidecar injected by barman-cloud-plugin chart in cnpg-system. Config lives in ObjectStore CR, referenced by Cluster via `spec.plugins`. Recovery manifests are generated dynamically by `db:restore` via `helm template` + `yq` — no static recovery templates to drift.
```

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with new restore task documentation"
```

---

### Task 5: Live verification with db:restore-verify

**Step 1: Run the DR test**

Run: `task db:restore-verify`

Expected output:
```
=== CNPG Restore Verification (Non-destructive) ===

Running pre-flight checks...
  Backups: 3 completed
  Latest: cnpg-cluster-on-demand-20260226154007
  Recovery window: 2026-02-26T00:00:00Z → now

Generating temporary cluster manifest...
Applying temporary cluster (1 instance)...
Waiting for temporary cluster to become healthy (timeout: 10 min)...
Pod is running.
Temporary cluster is healthy.
Validating database connectivity...
Database 'gitea' is accessible.

Restore test PASSED. Recovery took Xm Ys.

Cleaning up temporary cluster...
Cleanup complete. Production cluster was not affected.
```

**Step 2: Verify cleanup was complete**

Run:
```bash
kubectl get cluster -n cnpg-cluster
kubectl get pvc -n cnpg-cluster
```

Expected: Only `cnpg-cluster` resources exist. No `cnpg-cluster-restore-test` leftovers.

**Step 3: Verify production cluster is unaffected**

Run: `task db:status`

Expected: Cluster reports healthy, same as before the test.
