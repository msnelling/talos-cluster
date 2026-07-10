# CNPG on local storage — ending the postgres iSCSI cascade

## Summary

Move the CNPG PostgreSQL instance volumes off Longhorn/iSCSI onto node-local
storage, making CNPG's own streaming replication the sole HA layer for the
database. This removes the failure mode that wedged three nodes in three
separate incidents on 2026-07-10 (and previously on 2026-04-27): an iSCSI blip
under a write-hot postgres volume aborts the EXT4 journal, the filesystem goes
read-only, and the node's control plane wedges until reboot.

Interim mitigations (shipped alongside this doc, ahead of the migration):

1. `concurrentReplicaRebuildPerNodeLimit: 2 → 1` — serialize Longhorn rebuilds
   so post-reboot recovery I/O stays below the level that starves iSCSI and
   etcd fsync.
2. `task day2:upgrade-talos` pre-flight gate — refuses to start while any
   Longhorn volume is degraded/faulted.
3. Post-node health gate hardened — a rolling upgrade cannot drain node N+1
   until node N is Ready *and* all attached volumes are healthy again (and now
   fails loudly instead of timing out silently).

## Incident context (2026-07-10)

Three cascades in ~2 hours, all the same mechanism, different triggers:

| Time (UTC) | Trigger | Victim | Effect |
|---|---|---|---|
| ~08:00 | Drain of lenovo2 (`upgrade-talos`) churned its instance-manager | lenovo1 | postgres volume journal abort → NotReady; CNPG operator stranded; drain deadlocked |
| ~09:58 | Post-lenovo2-reboot rebuild storm (18 degraded volumes) | lenovo1 | postgres journal abort → NotReady (self-recovered when FS remounted r/w) |
| ~10:20 | Same rebuild storm | lenovo3 | postgres journal abort → NotReady; etcd fsync latency hit 10s, quorum margin lost |

Recovery each time: reboot the wedged node (per the 2026-04-27 postmortem),
CNPG failover restored the primary. No data loss — Longhorn's on-disk replica
survives; only the host's iSCSI view of the block device dies.

## Root cause chain

```
rebuild storm / instance-manager churn
  → iSCSI session drops or stalls past the kernel initiator's replacement_timeout (120s)
    → SCSI device marked offline mid-write
      → EXT4 journal abort (postgres is the write-hot workload that always has
        an fsync in flight — plex/alertmanager ride out the same blip)
        → filesystem read-only → postgres wedges
          → co-located control-plane static pods block on the dead mount
            → kubelet stops posting status → node NotReady
```

The database volumes are `longhorn-single-replica` (`numberOfReplicas: 1`,
`dataLocality: best-effort`) — Longhorn adds **no redundancy** for them, only
an iSCSI hop between postgres and the local disk it was already effectively
pinned to. CNPG's streaming replication across the three instances is the real
HA layer. We currently pay for two replication layers and get the benefit of
neither: Longhorn replicates nothing (1 replica) and its transport is the
thing that fails.

## Options considered

| Option | Verdict | Why |
|---|---|---|
| **Local PVs for CNPG** | **Chosen** | Removes the iSCSI hop entirely; no transport to blip. CNPG replication + barman S3 already provide HA/DR. Reduces total cluster I/O (no more write-hot volumes on Longhorn → smaller rebuild storms for everything else). CNPG upstream recommends local storage. |
| Multi-replica Longhorn for CNPG | Rejected | Fixes "one blip faults the volume" but amplifies postgres WAL writes 2-3× across the network onto the same disks etcd fsyncs to (etcd latency nearly cost quorum on 2026-07-10), adds more rebuild traffic per reboot (the trigger), and block-replicates bytes CNPG already stream-replicates. |
| iSCSI `replacement_timeout` tuning | Complement, not fix | Widens the survivable-blip window for *all* Longhorn volumes; worth doing (see Follow-ups) but a 6-minute instance-manager gap (April incident) still exceeds any sane timeout. |
| Longhorn V2 (SPDK) engine | Deferred | Bypasses the kernel iSCSI initiator, so it does attack the mechanism — but least mature option and a platform-wide migration. Revisit once stable. |

## Target architecture

```
cnpg-cluster-N pod ──fsync──> local PV (node disk, no network)
        │
        └─ streaming replication ──> other instances (CNPG-managed HA)
        └─ barman-cloud plugin ──> S3 (WAL archive + base backups, unchanged)
```

- **Provisioner:** a dynamic local-PV provisioner deployed as a wrapper chart
  at `cluster/apps/local-path-provisioner/` in the **platform** group.
  Candidates (verify published chart + version with `helm search repo` at
  implementation time — never guess):
  - Rancher `local-path-provisioner` — simplest, hostPath-based.
  - OpenEBS `localpv-provisioner` (repo `https://openebs.github.io/dynamic-localpv-provisioner`) — same model, actively published chart.
- **Data path:** under `/var` (e.g. `/var/mnt/local-path-provisioner`) — the
  only writable tree on Talos. Verify at implementation whether a
  `machine.kubelet.extraMounts` patch (same pattern as `patches/longhorn.yaml`)
  is needed for the chosen provisioner; if so it requires `task reconfigure` +
  rolling reboot **with the new pre-flight gate in place**.
- **StorageClass:** `local-hostpath` (or provisioner default), with
  `volumeBindingMode: WaitForFirstConsumer` (mandatory — binds the PV on the
  node where the pod schedules) and `reclaimPolicy: Retain`.
- **Namespace PodSecurity:** provisioner helper pods may need a `privileged`
  namespace label (same pattern as Longhorn's namespace template).
- **CNPG:** `cluster/apps/cnpg-cluster/values.yaml` `storage.storageClass:
  longhorn-single-replica → local-hostpath`. The existing **required** pod
  anti-affinity (one instance per node) already gives correct placement; it
  was added precisely because single-replica storage makes co-location a SPOF.
- **What stays on Longhorn:** everything else. `pgadmin-data` (default
  `longhorn` SC) is low-write and fine.

Trade-off accepted: instance data becomes node-pinned. A lost node takes its
instance's PVC with it; the operator rebuilds a replacement from the primary
via `pg_basebackup` (~10Gi, already the observed recovery path — e.g.
cnpg-cluster-4's rebuild). DR remains barman/S3, exercised by
`task db:restore-verify`.

## Migration plan (one instance at a time, no downtime)

Pre-conditions (abort if any fail):

- `task db:status` — cluster healthy, 3/3 ready, WAL archiving green.
- `task db:backup` + confirm completion (`task db:backups`).
- `task db:restore-verify` passes (proves S3 DR before touching storage).
- All Longhorn volumes healthy; no node cordoned.

Steps:

1. Land the provisioner app + StorageClass via ArgoCD (no impact on running
   workloads). Smoke-test with a scratch PVC + pod on each node, then delete.
2. If a Talos patch is required for the data path: apply via
   `task reconfigure`, rolling reboot one node at a time, gated on
   volume health (the hardened upgrade gate pattern).
3. Change `storage.storageClass` in `cluster/apps/cnpg-cluster/values.yaml`,
   push. **Validation checkpoint:** confirm the CNPG operator/webhook accepts
   the change on the live Cluster CR (it applies only to future PVCs). If the
   webhook rejects in-place change, fall back to the blue-green path below.
4. For each **standby** instance in turn:
   - Delete the instance pod + its PVC (the documented recovery pattern from
     CLAUDE.md: operator creates a replacement instance with a new serial).
   - The replacement provisions on `local-hostpath` (WaitForFirstConsumer pins
     it to the anti-affinity-chosen node) and clones from the primary via
     `pg_basebackup`.
   - Wait for `task db:status` to show 3/3 ready and replication streaming
     before touching the next instance.
5. Switchover: promote a migrated standby (`kubectl cnpg promote` /
   `spec.switchover`), wait for it to settle, then migrate the old primary the
   same way (step 4).
6. Verify: `task db:status`, `task db:backup`, `task db:restore-verify`, and
   app connectivity (gitea, grafana, jellyseerr).
7. Cleanup: keep the `longhorn-single-replica` SC for now — `gitea-runner`
   still uses it (see Follow-ups). Remove once nothing references it
   (StorageClass parameters are immutable; removal is delete-and-gone).

Fallback (blue-green), only if step 3's in-place class change is rejected:
stand up a second CNPG `Cluster` as a replica cluster of the first on the new
SC, let it sync, switch applications' secrets/services over during a short
window, then retire the old cluster.

Rollback at any point: reverse the storageClass change and recreate migrated
instances back onto Longhorn one at a time — the primary keeps serving
throughout; S3 PITR is the backstop.

## Follow-ups (separate changes, not this migration)

- **iSCSI timeout tuning** for the remaining Longhorn volumes: investigate a
  Talos `ExtensionServiceConfig` for the iscsi-tools extension raising
  `node.session.timeo.replacement_timeout` above the worst observed
  instance-manager recovery gap, so media apps survive blips postgres no
  longer sees.
- **gitea-runner** (`longhorn-single-replica`, cache-like data): move to the
  local SC or an emptyDir; it does not need Longhorn either.
- **Revisit Longhorn V2** when the SPDK engine is production-ready.

## Rejected: doing nothing

The cluster currently cannot absorb a node reboot: every reboot degrades ~18
volumes, and the resulting rebuild traffic has a proven ability to take down
the *other* nodes' postgres volumes. Until the DB is off iSCSI, node
maintenance remains a hands-on, cascade-prone operation — the opposite of the
GitOps/hands-off goal of this repo.
