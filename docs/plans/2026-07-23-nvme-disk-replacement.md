# Replacing the SATA SSDs in lenovo2 and lenovo3 with NVMe

## Summary

Swap the single system SSD in lenovo2 and lenovo3 for NVMe drives. Because Talos
keeps the OS, `/var`, etcd, Longhorn replicas and the openebs local PVs all on
one disk, each swap is a **full node rebuild**: graceful reset → physical swap →
reinstall from the secure-boot ISO in maintenance mode → rejoin the cluster.

**lenovo3 goes first.** It currently holds no Longhorn replicas at all
(`allowScheduling: false`, the mitigation for its failing ADATA SU630), so
wiping it destroys no replicated data. Only once lenovo3 is back on NVMe *and*
schedulable is there a third node to evacuate lenovo2's replicas onto. Doing
lenovo2 first would leave every db3000 volume on a single copy on lenovo1 for
the duration of the rebuild.

## Why this is a full rebuild

Every node boots from one disk and puts everything on it:

| Partition | Contents |
|---|---|
| EFI / META / STATE | Talos itself and the machine config |
| EPHEMERAL (`/var`, 238 GB) | etcd, containerd, `/var/lib/longhorn` replicas, `/var/openebs/local` PVs |

Talos reads `machine.install.disk` only during install, from maintenance mode.
There is no in-place migration to a new device, and `talosctl upgrade` reinstalls
to the disk the node already booted from. A USB boot of the secure-boot ISO is
therefore unavoidable — which is fine, since the machine is open anyway.

## Starting state (2026-07-23)

- Talos v1.13.7, Kubernetes v1.36.2, three control-plane nodes, etcd 3/3.
- Install disks: lenovo1 `LITEONIT LCS-256L9S`, lenovo2 `ADATA SU800`,
  lenovo3 `ADATA SU630` (failing — see the SU630 notes in the 2026-04-27 and
  2026-07-10 docs for the cascade it causes).
- `nodes.longhorn.io lenovo3` has `allowScheduling: false`; **all 20 Longhorn
  volumes have their replicas on lenovo1 and lenovo2 only**, all healthy.
- `defaultReplicaCount: 2`, `replica-soft-anti-affinity: false` (hard),
  `concurrentReplicaRebuildPerNodeLimit: 1`, `nodeDrainPolicy: always-allow`.
- CNPG is on `local-hostpath` (node-pinned, `reclaimPolicy: Retain`):
  `cnpg-cluster-1`→lenovo3, `-2`→lenovo1, `-3`→lenovo2 (primary).
  `gitea-runner` data is also local-hostpath on lenovo3.

## Phase 0 — preparation

Complete all of it before touching hardware.

1. **Confirm the hardware.** Verify both machines have a free M.2 2280 NVMe
   slot. Confirm the nodes have DHCP reservations — the rejoin assumes they come
   back on the same IPs; if not, `vars.yaml` needs the new IP as well.
2. **Fresh ISO.** `downloads/metal-amd64-secureboot.iso` must match the running
   Talos version. Re-download and write to USB:

   ```bash
   task setup:download
   diskutil list                        # identify the USB device
   diskutil unmountDisk /dev/diskN
   sudo dd if=downloads/metal-amd64-secureboot.iso of=/dev/rdiskN bs=4m status=progress
   ```

   Secure Boot keys live in BIOS NVRAM, so swapping the disk does not disturb
   enrolment.
3. **Backups.** `task db:backup` → `task db:backups` → `task db:restore-verify`.
   Confirm recent Longhorn backups with
   `kubectl -n longhorn-system get backups.longhorn.io` (the `daily-backup`
   recurring job covers all 20 volumes).
4. **Health gate.** All Longhorn volumes healthy, etcd healthy, no node
   cordoned. Abort if any of these fail.

## Phase 1 — lenovo3 (10.1.1.203)

### Evacuate and reset

```bash
# Confirm the CNPG primary is not on lenovo3
kubectl get cluster -n cnpg-cluster

kubectl cordon lenovo3
kubectl drain lenovo3 --ignore-daemonsets --delete-emptydir-data --force

# Graceful reset: leaves etcd cleanly and wipes cluster secrets off a disk
# that will be removed from the building
talosctl --context lenovo -n 10.1.1.203 reset --graceful=true --reboot --wipe-mode all

# Quorum must now show two healthy members
talosctl --context lenovo -n 10.1.1.140 etcd members

kubectl delete node lenovo3
kubectl delete nodes.longhorn.io lenovo3 -n longhorn-system   # clears the stale disk UUID
```

### Swap

Power off, remove the SATA SSD, fit the NVMe. **Do not leave the old SSD
installed** — two bootable Talos installs invite boot-order ambiguity and leave
stale Longhorn/openebs data on disk.

### Reinstall and rejoin

```bash
# Boot the USB into maintenance mode, then confirm the device path.
# --insecure is a flag of `get`, so it must follow the subcommand.
talosctl -n 10.1.1.203 get disks --insecure
talosctl -n 10.1.1.203 get discoveredvolumes --insecure   # expect a blank disk, no EFI/STATE/EPHEMERAL

# Update vars.yaml:  lenovo3  disk: /dev/nvme0n1

task day2:join-node -- lenovo3
talosctl --context lenovo -n 10.1.1.203 dmesg -f
```

`join-node` regenerates the machine config from `generated/secrets.yaml`,
re-applies every patch (longhorn, local-path-provisioner, logging, VIP,
Tailscale) and installs to the new disk. Verify: node Ready, `etcd members` back
to three, Cilium agent running.

### Clean up node-pinned volumes

The rebuilt node comes back with the old PVCs still `Bound` to `local-hostpath`
PVs whose backing directories went with the old disk. Their pods are recreated
immediately by the CNPG operator and the runner StatefulSet, and fail with:

```
MountVolume.NewMounter initialization failed for volume "pvc-…":
path "/var/openebs/local/pvc-…" does not exist
```

**Deleting the PVC first does not work.** `kubernetes.io/pvc-protection` holds
the delete open for as long as a pod references the claim, and the controller
keeps recreating that pod — the PVC sits in `Terminating` indefinitely. The pod
and the PVC have to go together.

For CNPG use the plugin's `destroy`, which removes the instance pod and its PVC
in one operation, leaving no window for the operator to re-reference the claim:

```bash
kubectl cnpg destroy cnpg-cluster 1 -n cnpg-cluster   # instance number, not pod name
```

The operator then rebuilds the instance via `pg_basebackup` from the primary
(a `cnpg-cluster-1-join-…` pod). The instance keeps its original name.

For the runner StatefulSet, delete the claim without waiting, then the pod — once
the pod is gone the finalizer clears, the claim is removed, and the StatefulSet
recreates both against a freshly provisioned volume:

```bash
kubectl delete pvc -n gitea-runner data-runner-gitea-runner-runner-0 --wait=false
kubectl delete pod -n gitea-runner gitea-runner-runner-0
```

The PVs are `reclaimPolicy: Retain`, so both linger as `Released` with no data
behind them and must be removed by hand:

```bash
kubectl get pv -o json | jq -r '.items[] | select(.status.phase=="Released") | .metadata.name'
kubectl delete pv <name>
```

Finally confirm the database is whole again — 3/3 ready, all instances at the
same LSN, WAL archiving OK with nothing waiting:

```bash
kubectl cnpg status cnpg-cluster -n cnpg-cluster
```

### Re-admit lenovo3 to Longhorn

```bash
kubectl patch nodes.longhorn.io lenovo3 -n longhorn-system --type merge \
  -p '{"spec":{"allowScheduling":true}}'
```

This starts `replicaAutoBalance` rebuilds. They are throttled to one per node,
but this is still the rebuild-storm pattern from the 2026-07-10 incidents — do it
in a quiet window and watch `kubectl get volumes.longhorn.io -A -w`. Wait for
every volume healthy, including the third replica on the 3-replica volumes
(gitea-shared-storage, minecraft-server-mc1/2/3, pgadmin-data), before Phase 2.

Expect only the 3-replica volumes to move. `replicaAutoBalance` evaluates each
volume independently, and a 2-replica volume spread across two nodes is already
balanced from its own point of view — so the db3000 volumes stay on
lenovo1+lenovo2 even though lenovo3 is now empty and schedulable. That is
correct, not a stalled rebalance: their move happens during the Phase 2
eviction, which is what keeps two copies live throughout. Budget for it —
roughly 140 GiB of replica data, serialised one rebuild at a time.

## Phase 2 — lenovo2 (10.1.1.146)

lenovo2 holds live replicas, so evacuate **before** wiping rather than rebuilding
after. Same total rebuild traffic, but the volume never drops below two copies.

```bash
# Evict Longhorn replicas onto lenovo1/lenovo3
kubectl patch nodes.longhorn.io lenovo2 -n longhorn-system --type merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'

# Wait until this returns nothing and every volume is healthy
kubectl get replicas.longhorn.io -n longhorn-system -o json \
  | jq -r '.items[] | select(.spec.nodeID=="lenovo2") | .spec.volumeName'

# Move the postgres primary off lenovo2
kubectl cnpg promote cnpg-cluster -n cnpg-cluster cnpg-cluster-2
```

Then repeat Phase 1's reset → swap → rejoin against `10.1.1.146` / lenovo2,
followed by the same node-pinned volume cleanup — `kubectl cnpg destroy
cnpg-cluster 3` this time, and no gitea-runner volume to deal with — then:

```bash
kubectl patch nodes.longhorn.io lenovo2 -n longhorn-system --type merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
```

Eviction relaxes hard anti-affinity rather than leaving volumes degraded, so the
3-replica volumes end the window with **two or three copies stacked on lenovo1**
(observed: `minecraft-server-mc1/2/3`, `pgadmin-data`, `pvc-fc8b…` all at
`lenovo1 ×3, lenovo3`, i.e. one replica *over* spec). Every volume still reports
healthy, because from Longhorn's point of view the replica count is satisfied —
but three copies on one node is one failure domain, not three, and it fills the
remaining node's disk. Do not treat "all healthy" as "correctly placed" here;
check placement, not just robustness:

```bash
kubectl get replicas.longhorn.io -n longhorn-system -o json \
  | jq -r '[.items[] | {v:.spec.volumeName, n:.spec.nodeID}] | group_by(.v)[]
           | "\(.[0].v)\t\(map(.n)|sort|join(","))"'
```

Re-enabling scheduling on the rebuilt node clears this on its own — but
**slowly**, because rebuilds are serialised by
`concurrentReplicaRebuildPerNodeLimit: 1`. It converged fully here in under ten
minutes, one volume at a time, ending at exactly one replica per node with the
total replica count back to spec. Counts sitting still for a minute or two mean
nothing: only one volume is being worked on at a time and the rest are queued.
**Do not hand-delete the surplus replicas to force it** — that adds rebuild
traffic to a cluster with a cascade history, to accelerate something that
finishes by itself. Sample placement a few minutes apart before concluding
anything is stuck.

## Abort criteria

Stop and stabilise rather than continuing to the next step if any of these
appear:

- Any node goes NotReady.
- Any Longhorn volume reports `faulted`, or `unknown` on a node that is up.
- etcd logs slow fdatasync warnings, or `talosctl etcd status` shows a member
  falling behind.

This is the known cascade: a stalled disk stalls raft, the local kube-apiserver
blocks, KubePrism round-robins a third of every node's requests into it, kubelet
leases fail and all three nodes go NotReady. Each phase therefore gates on
*volume health*, not merely on the node reporting Ready.

## Verification and follow-ups

- `task db:status`, `task db:backup`, `task db:restore-verify`.
- Check application connectivity: gitea, grafana, seerr.
- `kubectl get volumes.longhorn.io -A` — all healthy at their target replica
  count, **and** one replica per node in the placement query above.
- `talosctl get systemdisk` on each rebuilt node — confirm it resolves to
  `nvme0n1`, not a leftover `sda`.
- `talosctl etcd members` — three members, and the rebuilt node carries a *new*
  member ID (proof the old member left cleanly rather than being reused).

## Outcome (2026-07-23)

Both swaps completed the same day. lenovo2 and lenovo3 now run 1 TB NVMe
(`WD_BLACK SN7100`, 928 GiB usable to Longhorn each); etcd 3/3, CNPG 3/3
streaming with one instance per node, all 20 volumes healthy and evenly placed.

**Final state:** all 20 volumes hold two replicas, one on lenovo2 and one on
lenovo3 — SATA is out of every volume's write path. lenovo1 was evicted
(`allowScheduling: false` + `evictionRequested: true`), which relocated ~89 GiB
across 14 replicas onto lenovo2 with no volume ever dropping below two copies
and no node leaving Ready. Scheduling was then re-enabled with
`evictionRequested: false`, leaving lenovo1 empty but eligible: it is the only
rebuild target if an NVMe node is lost, which is why it was not simply excluded.

**lenovo1 cannot take an NVMe** — different, older hardware with no M.2 slot. So
this is the permanent topology: two fast nodes and one slow one, not a state to
be upgraded out of.

### Replica counts: nothing here needs three

Six volumes were still at `numberOfReplicas: 3` — historical drift from when the
default was 3. Nothing in git pinned them there (the `longhorn` StorageClass
already specifies 2, and the static PV templates for gitea/pgadmin declare
`numberOfReplicas: "1"` in `volumeAttributes`, which never applied because those
attributes only take effect when Longhorn *creates* the volume, not when a PV
references an existing one by `volumeHandle`).

A third replica buys survival of two simultaneous node losses. On three nodes,
two nodes down means etcd has lost quorum and nothing is running anyway — so it
protects data in a scenario where the workload cannot function regardless. That
is what the daily S3 backups are for. Against that, the third replica costs a
synchronous write to a third disk, 50% more rebuild traffic on every reboot (the
cascade trigger), and more CRD churn in etcd.

**This is also the precondition for keeping SATA out of the write path.** With
hard anti-affinity on three nodes, a 3-replica volume has no placement freedom:
one replica per node, so lenovo1 is *mandatorily* in every write path. You
cannot have both three replicas and NVMe-only placement.

All six were dropped to 2 on 2026-07-23. Longhorn removed the lenovo1 replica
from each, so they landed on lenovo2+lenovo3 — entirely on NVMe, with no rebuild
traffic, since reducing a replica count only deletes surplus replicas.

### Prioritising the fast disks

Longhorn tags (`diskSelector`/`nodeSelector` on a StorageClass) are a **hard
filter, not a preference**. Tagging only the NVMe pair means lenovo1 cannot hold
those replicas even as a rebuild target — and with two eligible nodes and hard
anti-affinity, a single node outage leaves the volume on one replica with
nowhere to rebuild until it returns. Today, with three eligible nodes and two
replicas, a node loss self-heals onto the spare.

Prefer to leave lenovo1 untagged and schedulable, and let free space do the
work: Longhorn favours disks with more available space, and 928 GiB nodes keep
beating a 236 GiB one, so new volumes tend toward NVMe on their own — as
observed when the six volumes above shed exactly their lenovo1 replica. That is
a tendency, not a guarantee; reach for tags only if a specific volume must never
touch SATA, and accept losing the rebuild target for it.

Note the tendency only applies when Longhorn is *choosing* a replica location.
It never relocates a healthy existing replica, which is why the 14 volumes
already at two replicas stayed on lenovo1 until they were explicitly evicted.

### The SU800 was not fitted to lenovo1

lenovo1's LITEONIT was a candidate for replacement by the healthy SU800 pulled
from lenovo2, on the theory that an unknown decade-old drive should not sit
under etcd and the CNPG local PV — the two most fsync-sensitive workloads, and
now the only things left on it. SMART says otherwise:

| Attribute | Raw |
|---|---|
| `Reallocated_Sector_Ct` | 0 |
| `Reported_Uncorrect` | 0 |
| `Program_Fail_Cnt_Total` / `Erase_Fail_Count_Total` | 0 |
| `Used_Rsvd_Blk_Cnt_Tot` | 0 (of 1952 spare blocks) |
| normalised value / worst | 100 / 100 |

Every wear and error indicator reads zero. Two caveats: the drive reports **no
`Power_On_Hours` attribute at all**, so its age cannot be quantified, and the
raw `Total_LBAs_Written` figure uses an undocumented vendor multiplier, so it
should not be converted to terabytes written.

The comparison could not be completed either way — the SU800 was already out of
the fleet, so its own SMART cannot be read without fitting it somewhere. Swapping
a measurably clean drive for an unreadable one, at the cost of a third node
rebuild, is not justified. **The SU800 is kept as a cold spare.** Revisit if
`Reallocated_Sector_Ct` ever moves off zero — which now pages.

### Monitoring added alongside this work

None of the decisions above could be made from data when the day started:
nothing scraped Longhorn, and no SMART was collected anywhere. lenovo3's SU630
failure had been caught only by kernel ATA timeouts, i.e. after it was already
starving etcd. Four changes closed that:

- **Longhorn ServiceMonitor** — `longhorn_volume_*` per-volume throughput, IOPS
  and latency now reach Prometheus.
- **smartctl-exporter** — privileged DaemonSet with `/dev` bind-mounted, in its
  own privileged-labelled namespace, since Talos ships no smartmontools
  extension (`nvme-cli` exists; nothing reads SATA SMART).
- **Per-node device selection** — the exporter's autoscan enumerated every
  Longhorn iSCSI device. Neither scan type nor a name regexp can separate them
  (a SATA disk scans as `-d scsi` exactly like iSCSI; and `/dev/sda` is the real
  disk on lenovo1 but an iSCSI device on the NVMe nodes, which no longer have a
  SATA disk). Devices are therefore listed explicitly per disk type, keyed on a
  `xmple.io/disk-type` node label set from `machine.nodeLabels` and derived from
  the install disk in `vars.yaml` — so it survives a rebuild, unlike Longhorn's
  node tags, which were lost during this very exercise.
- **ATA wear alerts + a Storage Health dashboard** — the upstream chart's alerts
  read NVMe SMART log fields that do not exist on SATA, leaving reallocated
  sectors and uncorrectables unalerted on the one drive that most needs them.

**Metric gotcha worth knowing:** replica placement is `longhorn_replica_info`.
The `node` label on `longhorn_volume_*` is the *attachment* (engine) node, which
is a different thing and easy to misread as placement.

### Remaining follow-ups

- Optional: refit lenovo2's healthy SU800 in its SATA bay as a second Longhorn
  data disk for capacity. The SU630 should be binned.
- `defaultReplicaCount` stays at 2. See the replica-count reasoning above — with
  lenovo1 permanently SATA, raising it to 3 would put the slow disk back into
  every write path.
