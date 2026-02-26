# Design: Harden CNPG Backup/Restore Process

**Date:** 2026-02-26
**Status:** Draft

## Problem

The current restore process has several fragilities exposed during the barman cloud plugin migration:

1. **Destructive-first workflow.** `restore-prep` deletes the production Cluster CR before the backup is validated. If the backup is bad (as happened with the timeline mismatch), you're left with no cluster and no way back.

2. **Manual manifest drift.** `cluster-restore.yaml` is a hand-maintained copy of the Cluster spec. It hardcodes values (instances: 3, storage size, S3 endpoint) that can drift from the Helm chart's `values.yaml`. When it drifts, restores break silently.

3. **No pre-flight validation.** Nothing checks that a valid recovery window exists before proceeding. If WAL archiving is failing or no completed backup exists, the restore attempt will fail after the cluster is already deleted.

4. **No rollback path.** If restore-apply fails, the only recovery is to resume ArgoCD and let it recreate with `initdb` (losing data), or manually debug. There's no automated "abort and roll back" step.

5. **ArgoCD race condition (now fixed).** The original task only paused `app-data` (the group), not the `cnpg-cluster` Application itself. Self-heal recreated the Cluster immediately after deletion, causing a timeline split. This is fixed but illustrates how the destructive approach amplifies bugs.

## Design: Non-Destructive Restore

### Core principle

**Validate the backup by restoring to a temporary cluster first.** Only delete the production cluster after confirming the restore actually works.

### New restore flow

```
task db:restore                          # Single command, replaces 3-step flow
  ├── Pre-flight checks
  │   ├── Verify completed backup exists
  │   ├── Verify WAL archiving is OK
  │   └── Verify recovery window covers target time (if PITR)
  ├── Restore to temporary cluster (cnpg-cluster-restore-test)
  │   ├── Generate manifest from Helm values (no manual template)
  │   ├── Apply with bootstrap.recovery
  │   └── Wait for healthy state
  ├── Validate restored data
  │   ├── Cluster reports healthy
  │   └── Print row counts / schema summary for manual verification
  ├── Confirmation prompt
  │   └── "Restore verified. Replace production cluster? (yes/no)"
  ├── Swap clusters
  │   ├── Pause ArgoCD (both cnpg-cluster app and app-data group)
  │   ├── Delete production Cluster CR
  │   ├── Delete temporary cluster
  │   ├── Resume ArgoCD → recreates from chart template with initdb
  │   └── (CNPG won't re-init because PVCs from restore-test are gone;
  │        fresh initdb is expected — the real data lives in the backup)
  └── Post-restore
      ├── Wait for healthy state
      └── Print status
```

Wait — there's a subtlety. The goal of restore is to get the data back into the production cluster. Simply validating the backup and then re-creating with `initdb` loses the data. We need a different swap strategy.

### Revised swap strategy

After the temporary cluster validates successfully:

```
  ├── Swap clusters
  │   ├── Pause ArgoCD (cnpg-cluster app + app-data group)
  │   ├── Delete temporary cluster (cnpg-cluster-restore-test)
  │   ├── Delete production Cluster CR (not the PVCs/data)
  │   ├── Apply recovery Cluster CR as "cnpg-cluster" (the production name)
  │   │   └── Same recovery config that worked on the temp cluster
  │   ├── Wait for healthy
  │   ├── Resume ArgoCD
  │   └── ArgoCD re-syncs the chart template (switches from recovery to initdb)
  │        → CNPG ignores initdb because data directory already exists
```

This is essentially what the current flow does, but with the critical addition of a pre-validation step using a temporary cluster.

### Alternative: Restore-in-place with pre-flight only

A simpler approach that keeps the current flow but adds safety:

```
task db:restore [-- "PITR-timestamp"]
  ├── Pre-flight checks (BLOCKS if any fail)
  │   ├── At least one backup with phase: completed
  │   ├── WAL archiving status is OK
  │   ├── If PITR: target time is within recovery window
  │   └── Print backup list + recovery window for human review
  ├── Confirmation prompt
  ├── Pause ArgoCD (cnpg-cluster + app-data)
  ├── Delete Cluster CR
  ├── Wait for pod termination
  ├── Apply recovery Cluster CR
  ├── Wait for healthy (with timeout)
  │   └── On timeout: print diagnostic info, suggest manual intervention
  ├── Resume ArgoCD
  └── Print final status
```

### Eliminating manifest drift

Both approaches need a way to generate the recovery Cluster CR from the chart values rather than maintaining a separate template.

**Option A: `helm template` + yq transformation**

```bash
# Render the chart, extract the Cluster CR, replace bootstrap.initdb with bootstrap.recovery
helm template cnpg-cluster cluster/apps/cnpg-cluster \
  | yq 'select(.kind == "Cluster")' \
  | yq '.spec.bootstrap = {"recovery": {"source": "cnpg-cluster-backup"}}' \
  | yq '.spec.externalClusters = [{"name": "cnpg-cluster-backup", "plugin": {"name": "barman-cloud.cloudnative-pg.io", "parameters": {"barmanObjectName": "cnpg-cluster-backup"}}}]' \
  | kubectl apply -f -
```

This is the cleanest approach — the Cluster spec always matches the chart, and only the bootstrap method is swapped. The recovery-specific fields (externalClusters, bootstrap.recovery) are injected by the task.

**Option B: Keep separate template, validate against chart**

Keep `cluster-restore.yaml` but add a CI check that diffs the non-recovery fields against `helm template` output. More fragile — the CI check could be wrong or incomplete.

**Recommendation: Option A.** Eliminates the drift problem entirely. The `cluster/recovery/cluster-restore.yaml` template is deleted. The `cluster/recovery/backup.yaml` template stays (it's simple and doesn't duplicate chart values).

### Pre-flight check implementation

```bash
# 1. Check for completed backups
COMPLETED=$(kubectl get backups.postgresql.cnpg.io -n cnpg-cluster \
  -o jsonpath='{.items[?(@.status.phase=="completed")].metadata.name}')
if [ -z "$COMPLETED" ]; then
  echo "ERROR: No completed backups found. Cannot restore."
  exit 1
fi

# 2. Check WAL archiving
WAL_STATUS=$(kubectl cnpg status cnpg-cluster -n cnpg-cluster 2>&1)
if ! echo "$WAL_STATUS" | grep -q "Working WAL archiving.*OK"; then
  echo "WARNING: WAL archiving is not healthy. PITR may be limited."
  echo "$WAL_STATUS" | grep -A2 "Continuous Backup"
fi

# 3. If PITR, validate target time is within recovery window
# (Parse "First Point of Recoverability" from cnpg status output)
```

### Task consolidation

Replace the 3-step flow with 2 tasks:

| Task | Purpose |
|------|---------|
| `db:restore` | Full restore: pre-flight → pause ArgoCD → delete → apply recovery → wait → resume. Optional `-- "timestamp"` for PITR. |
| `db:restore-verify` | Non-destructive: restore to temporary cluster, validate, cleanup. For DR testing without touching production. |

The 3-step flow (`restore-prep` → `restore-apply` → `restore-finish`) is removed. The split was intended to give the operator control, but in practice it created gaps where things could go wrong (ArgoCD race, forgotten resume, manual errors between steps).

### DR testing with `db:restore-verify`

```
task db:restore-verify [-- "PITR-timestamp"]
  ├── Pre-flight checks (same as db:restore)
  ├── Generate temporary Cluster CR (cnpg-cluster-restore-test)
  │   └── helm template + yq, same as db:restore but different name
  │       and with reduced instances (1) for speed
  ├── Apply temporary cluster
  ├── Wait for healthy
  ├── Print status + basic data validation
  │   └── "Restore test PASSED. Recovery took Xm Ys."
  ├── Cleanup
  │   ├── Delete temporary Cluster CR
  │   └── Delete temporary PVCs
  └── "Production cluster was not affected."
```

This can be run regularly (even automated via CronJob) to validate that backups are actually restorable.

## Files to change

| File | Action |
|------|--------|
| `taskfiles/database.yaml` | Replace `restore-prep`/`restore-apply`/`restore-finish` with `restore` and `restore-verify` |
| `cluster/recovery/cluster-restore.yaml` | Delete (replaced by `helm template` + yq) |
| `cluster/recovery/backup.yaml` | Keep as-is |
| `CLAUDE.md` | Update restore documentation |

## Migration

The new `db:restore` task is a drop-in replacement. The 3-step tasks are removed. Users who memorized the old flow get a clear error pointing to the new command.

## Open questions

1. **Should `db:restore-verify` run with 1 instance or match production (3)?** One instance is faster but doesn't validate replication setup. Suggest 1 for routine testing, option to specify count.

2. **Should we add a scheduled restore test?** A CronJob that runs `db:restore-verify` weekly and alerts on failure would catch backup rot early. Out of scope for this PR but worth considering.

3. **What data validation should `restore-verify` perform?** At minimum: cluster healthy, can connect via psql, database exists. Could also run a user-provided SQL query.
