# Design: Harden CNPG Backup/Restore Process

**Date:** 2026-02-26
**Status:** Approved

## Problem

The current restore process has several fragilities exposed during the barman cloud plugin migration:

1. **Destructive-first workflow.** `restore-prep` deletes the production Cluster CR before the backup is validated. If the backup is bad, you're left with no cluster and no way back.

2. **Manual manifest drift.** `cluster-restore.yaml` is a hand-maintained copy of the Cluster spec. It hardcodes values (instances: 3, storage size, S3 endpoint) that can drift from the Helm chart's `values.yaml`.

3. **No pre-flight validation.** Nothing checks that a valid recovery window exists before proceeding.

4. **No rollback path.** If restore-apply fails, the only recovery is to resume ArgoCD and let it recreate with `initdb` (losing data), or manually debug.

5. **WAL gap on cluster deletion.** When the Cluster CR is deleted, the barman-cloud plugin sidecar may not finish archiving the final WAL segment before the pod terminates. This makes the most recent backup unrestorable. The destructive-first workflow makes this fatal.

See `docs/plans/2026-02-26-restore-hardening.md` for the full root cause analysis.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Task structure | Two tasks: `db:restore` + `db:restore-verify` | Production restore with pre-flight + separate DR testing tool |
| Manifest source | `helm template` + `yq` from local chart | Eliminates drift, always matches git, works offline |
| Pre-flight data source | `kubectl get` + jsonpath | Structured data, won't break if cnpg plugin output format changes |
| Temp cluster instances | Always 1 | Faster, fewer resources, replication validated by production |
| Data validation | Healthy + database exists (SELECT 1) | Sufficient without knowing table structure |
| WAL archiving in recovery | Omit from recovery manifest | ArgoCD re-sync adds plugins section within ~3 min |

## Manifest Generation

Both tasks share a common approach to generating Cluster CRs from the Helm chart, eliminating the hand-maintained `cluster-restore.yaml`.

**Base manifest:** Render the chart and extract the Cluster resource.

```bash
helm template cnpg-cluster cluster/apps/cnpg-cluster \
  | yq 'select(.kind == "Cluster")'
```

**Recovery transformation (shared):**

1. Replace bootstrap: `.spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}`
2. Add externalClusters: `.spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]`
3. Remove plugins section (ArgoCD re-adds on sync)
4. If PITR timestamp provided: add `.spec.bootstrap.recovery.recoveryTarget.targetTime`

**Additional transforms for `db:restore-verify`:**

5. Rename: `.metadata.name = "cnpg-cluster-restore-test"`
6. Scale: `.spec.instances = 1`

This deletes `cluster/recovery/cluster-restore.yaml` entirely.

## Pre-flight Checks

Both tasks run the same pre-flight checks before any action. All use structured JSON via `kubectl get`.

### Check 1: Completed backup exists (BLOCKING)

```bash
kubectl get backups.postgresql.cnpg.io -n cnpg-cluster \
  -o jsonpath='{.items[?(@.status.phase=="completed")].metadata.name}'
```

Blocks if no completed backups found. Lists available backups for operator review.

### Check 2: Cluster health (WARNING, db:restore only)

```bash
kubectl get cluster cnpg-cluster -n cnpg-cluster \
  -o jsonpath='{.status.phase}'
```

Warning if unhealthy — you might be restoring because it's unhealthy.

### Check 3: Recovery window (WARNING / BLOCKING for PITR)

```bash
kubectl get cluster cnpg-cluster -n cnpg-cluster \
  -o jsonpath='{.status.firstRecoverabilityPoint}'
```

If empty, warn that PITR may not work. If PITR requested and target time is before first recoverability point, block.

### Summary output

```
Backups: 3 completed
Latest: cnpg-cluster-on-demand-20260226-154007 (27m ago)
Recovery window: 2026-02-26T00:00:00Z → now
```

## Task: `db:restore` — Production Restore

Single command replaces the 3-step `restore-prep` → `restore-apply` → `restore-finish` flow.

```
task db:restore [-- "PITR-timestamp"]
  ├── Pre-flight checks
  ├── Print backup summary + recovery window
  ├── Generate recovery manifest (BEFORE any destructive action)
  │   └── helm template + yq
  │   └── If PITR: inject recoveryTarget.targetTime
  │   └── Abort if helm/yq fails
  ├── Confirmation prompt
  │   └── "This will DELETE the production cluster and restore from backup. Continue? (yes/no)"
  ├── Pause ArgoCD
  │   ├── kubectl patch application cnpg-cluster -n argocd ... automated=null
  │   └── kubectl patch application app-data -n argocd ... automated=null
  ├── Delete Cluster CR
  │   └── kubectl delete cluster cnpg-cluster -n cnpg-cluster --wait --timeout=120s
  ├── Wait for pod termination
  ├── Apply recovery manifest
  │   └── kubectl apply -f -
  ├── Wait for healthy (with timeout: 10 min)
  │   ├── Poll until at least 1 pod Running
  │   ├── Poll until cluster reports healthy
  │   └── On timeout: print diagnostics, do NOT auto-resume ArgoCD
  ├── Validate: connect to database, run SELECT 1
  ├── Resume ArgoCD auto-sync
  │   ├── kubectl patch application cnpg-cluster ... automated={prune:true,selfHeal:true}
  │   └── kubectl patch application app-data ... automated={prune:true,selfHeal:true}
  └── Print final status
```

**Key behaviors:**
- Manifest generation happens before the confirmation prompt — if helm/yq fails, nothing is destroyed.
- On health-check timeout, ArgoCD stays paused. The operator must investigate and either retry or resume manually.
- The confirmation prompt is the only manual gate.

## Task: `db:restore-verify` — Non-destructive DR Test

```
task db:restore-verify [-- "PITR-timestamp"]
  ├── Pre-flight checks
  ├── Print backup summary
  ├── Generate temp cluster manifest
  │   └── helm template + yq
  │   └── Name: cnpg-cluster-restore-test, instances: 1
  │   └── If PITR: inject recoveryTarget.targetTime
  ├── Apply temp cluster
  │   └── kubectl apply -f -
  ├── Wait for healthy (with timeout: 10 min)
  │   ├── Poll until pod Running
  │   ├── Poll until cluster reports healthy
  │   └── On timeout: cleanup and report failure
  ├── Validate: connect to database, run SELECT 1
  ├── Print result
  │   └── "Restore test PASSED. Recovery took Xm Ys."
  │   └── or "Restore test FAILED: <reason>"
  ├── Cleanup (always, even on failure — use trap)
  │   ├── Delete temp Cluster CR
  │   └── Delete temp PVCs: kubectl delete pvc -n cnpg-cluster -l cnpg.io/cluster=cnpg-cluster-restore-test
  └── "Production cluster was not affected."
```

**Key behaviors:**
- No confirmation prompt — nothing destructive happens to production.
- Always cleans up, even on failure (shell trap).
- Times the recovery for reporting.
- Uses same namespace (`cnpg-cluster`) to access ObjectStore and S3 secrets.

## Files to Change

| File | Action |
|------|--------|
| `taskfiles/database.yaml` | Replace `restore-prep`/`restore-apply`/`restore-finish` with `restore` and `restore-verify`. Add `_require-yq` precondition. Add shared helper tasks for pre-flight and manifest generation. |
| `cluster/recovery/cluster-restore.yaml` | **Delete** — replaced by `helm template` + `yq` |
| `cluster/recovery/backup.yaml` | Fix timestamp format: `%Y%m%d-%H%M%S` → `%Y%m%d%H%M%S` (match CNPG scheduled backup naming) |
| `CLAUDE.md` | Update restore task documentation |

## Dependencies

| Tool | Status | Notes |
|------|--------|-------|
| `helm` | Already required | Existing tasks use it |
| `kubectl` | Already required | Existing tasks use it |
| `yq` | **New dependency** | Add `_require-yq` precondition check |
| `kubectl-cnpg` | Already required | Used for `db:status`, health polling |

## Migration

The 3-step tasks (`restore-prep`, `restore-apply`, `restore-finish`) are removed. The new `db:restore` is a single-command replacement. Users who run old task names get Taskfile's standard "task not found" error.
