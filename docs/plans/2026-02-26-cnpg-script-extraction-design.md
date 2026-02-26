# Design: Extract CNPG Restore Scripts from database.yaml

**Date:** 2026-02-26
**Status:** Approved

## Problem

`taskfiles/database.yaml` is 347 lines, ~280 of which are bash scripts inside YAML string literals. The `restore` task is ~160 lines inline; `restore-verify` is ~120 lines. This causes:

1. **No linting.** Can't run shellcheck on inline YAML strings. Bugs in quoting and word splitting are invisible until runtime — which for `db:restore` means during an incident.
2. **No syntax highlighting.** Editors see YAML, not bash.
3. **No code sharing.** Pre-flight checks, manifest generation, and health polling are copy-pasted between the two tasks. The `serverName` bug (commits `760551e` → `5e72c8c`) proved this — fixed in one task, then a separate commit to fix the other.
4. **Untestable.** Can't run or test individual functions without executing the whole task.

Other taskfiles (day2, components, setup) also use inline scripts but stay under 35 lines each. The database tasks are the outlier.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Script location | `scripts/` at repo root | New directory, justified by complexity. Other taskfiles don't need this yet. |
| Shared code | `cnpg-lib.sh` sourced by both scripts | Eliminates duplication of pre-flight, manifest gen, health polling. Single place to fix bugs. |
| Manifest function API | Base + pipe (not parameters) | Function does the hard thing (recovery yq expression) once. Caller pipes trivial transforms (name, instances) at the call site where differences are visible. |
| Simple tasks | Stay inline in database.yaml | `status`, `backup`, `backups`, `psql` are one-liners. No benefit from extraction. |
| Behavioral changes | None | Same pre-flight checks, same restore flow, same cleanup. Pure structural refactor. |

## File Structure

```
scripts/
  cnpg-lib.sh              # Shared functions (sourced, not executed)
  cnpg-restore.sh           # Production restore
  cnpg-restore-verify.sh    # Non-destructive DR test
```

## Shared Library: `cnpg-lib.sh`

Sourced by both scripts. Expects caller to set `NAMESPACE`, `CLUSTER_NAME`, `CHART_PATH` before sourcing.

### `cnpg_get_db_name`

One-liner: `yq '.initdb.database' "$CHART_PATH/values.yaml"`. Both scripts need the database name; the path should be defined once.

### `cnpg_preflight`

Takes optional PITR target as `$1`. Prints summary and sets global variables:

- `BACKUP_COUNT`, `LATEST_BACKUP` — from completed backups query
- `FIRST_RECOVERABLE` — from cluster status

Exits 1 if no completed backups. Exits 1 if PITR target is before recovery window. Warns (non-fatal) if cluster is unhealthy or recovery window is empty.

### `cnpg_generate_recovery_manifest`

Takes optional PITR target as `$1`. Outputs base recovery manifest YAML to stdout. Runs `helm template` + `yq` pipeline with the recovery transformation:

- Replace bootstrap with `recovery` source
- Add `externalClusters` with barman-cloud plugin config (including `serverName`)
- Remove `plugins` section
- If PITR target provided, inject `recoveryTarget.targetTime`

Exits 1 if helm or yq fails, or if output is empty.

Callers capture output and pipe through additional transforms if needed:

```bash
# Production restore — use as-is
MANIFEST=$(cnpg_generate_recovery_manifest "$PITR_TARGET")

# Verify — rename and scale down
MANIFEST=$(cnpg_generate_recovery_manifest "$PITR_TARGET" \
  | yq '.metadata.name = "'"$TEMP_CLUSTER"'" | .spec.instances = 1')
```

### `cnpg_wait_for_healthy`

Takes cluster name as `$1`, timeout in seconds as `$2`. Polls:

1. At least one pod with `status.phase=Running`
2. Cluster reports `"Cluster in healthy state"`

Returns 0 on success. Exits 1 on timeout with diagnostic message.

## Taskfile Integration

`database.yaml` becomes a thin dispatch layer for restore tasks:

```yaml
restore:
  desc: "Restore CNPG cluster from backup (usage: task db:restore [-- \"PITR-timestamp\"])"
  deps: [_require-cnpg-plugin, _require-yq, _require-helm]
  interactive: true
  cmds:
    - scripts/cnpg-restore.sh {{.CLI_ARGS}}

restore-verify:
  desc: "Non-destructive DR test (usage: task db:restore-verify [-- \"PITR-timestamp\"])"
  deps: [_require-cnpg-plugin, _require-yq, _require-helm]
  interactive: true
  cmds:
    - scripts/cnpg-restore-verify.sh {{.CLI_ARGS}}
```

Simple tasks (`status`, `backup`, `backups`, `psql`) stay inline — they're one-liners with no duplication.

## Script Outlines

### `cnpg-restore.sh` (~60-70 lines)

1. Source lib, set constants, parse `$1` as PITR target
2. `cnpg_preflight "$PITR_TARGET"`
3. Print available backups table
4. `RECOVERY_MANIFEST=$(cnpg_generate_recovery_manifest "$PITR_TARGET")`
5. Confirmation prompt
6. Pause ArgoCD (two `kubectl patch` calls)
7. Delete Cluster CR + wait for pod termination (with timeout)
8. Apply recovery manifest
9. `cnpg_wait_for_healthy "$CLUSTER_NAME" 600`
10. Validate: `SELECT 1` via `kubectl cnpg psql`
11. Resume ArgoCD
12. Print final status

### `cnpg-restore-verify.sh` (~40-50 lines)

1. Source lib, set constants, parse `$1` as PITR target
2. Set up `cleanup()` trap (delete temp cluster, PVCs, PVs, Longhorn volumes)
3. `cnpg_preflight "$PITR_TARGET"`
4. Generate manifest with temp cluster transforms (pipe through yq)
5. Apply manifest
6. `cnpg_wait_for_healthy "$TEMP_CLUSTER" 600`
7. Validate + print recovery timing
8. Cleanup via trap

## What This Does NOT Change

- No behavioral changes to restore or restore-verify
- No robustness improvements (trap in restore, WAL flush, idempotency) — those are a separate follow-up
- No changes to simple database tasks
- No changes to other taskfiles
