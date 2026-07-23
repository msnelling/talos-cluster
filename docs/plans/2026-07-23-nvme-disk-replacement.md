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

The `local-hostpath` PVs are `Retain`, so they survive as `Released` with no data
behind them. Delete them and let the controllers rebuild:

```bash
kubectl delete pod  -n cnpg-cluster cnpg-cluster-1
kubectl delete pvc  -n cnpg-cluster cnpg-cluster-1     # operator rebuilds via pg_basebackup, new serial
kubectl delete pvc  -n gitea-runner data-runner-gitea-runner-runner-0
kubectl delete pod  -n gitea-runner runner-gitea-runner-runner-0
kubectl get pv | grep Released                         # delete the released local-hostpath PVs
kubectl cnpg status cnpg-cluster -n cnpg-cluster        # wait for 3/3 streaming
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
followed by the same PVC cleanup (`cnpg-cluster-3` this time; no gitea-runner
volume here), then:

```bash
kubectl patch nodes.longhorn.io lenovo2 -n longhorn-system --type merge \
  -p '{"spec":{"allowScheduling":true,"evictionRequested":false}}'
```

Expect the 3-replica volumes to report **degraded** throughout the eviction
window: with hard anti-affinity and only two schedulable nodes there is nowhere
for a third copy. They still hold two real replicas, and the status clears once
lenovo2 rejoins.

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
  count.
- Consider raising `defaultReplicaCount` back to 3 now that three healthy fast
  disks exist.
- lenovo1's LITEONIT SATA SSD becomes the slowest disk in the fleet and the last
  old drive — a candidate for a third NVMe later.
- Optional: refit lenovo2's healthy SU800 in its SATA bay as a second Longhorn
  data disk for capacity. The SU630 should be binned.
