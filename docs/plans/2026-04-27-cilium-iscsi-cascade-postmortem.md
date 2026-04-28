# Cilium-induced iSCSI cascade on lenovo2 — postmortem

## Summary

On 2026-04-27, lenovo2 went `NotReady` at 19:28 UTC after Longhorn iSCSI sessions
collapsed and EXT4 journals aborted on every Longhorn-attached volume on the
node. Trigger was the `fix(cilium): switch to BPF masquerade` rollout (#403),
merged at 17:36 BST. Recovery was a `talosctl reboot` of lenovo2; etcd quorum
held throughout (lenovo1 leader, lenovo3 in quorum), so the cluster API stayed
available and no other node was affected.

## Timeline (UTC, 2026-04-27)

| Time | Event |
|---|---|
| 16:36 | Cilium chart bump merged to `main` (BPF masquerade) |
| 17:28 | Cilium pods on lenovo1 and lenovo3 restart (ArgoCD sync) |
| ~17:30 | Cilium pod on lenovo2 restarts |
| 19:02 | longhorn-manager declares lenovo2 "node down or deleted"; every Longhorn instance on lenovo2 marked `unknown` |
| 19:10 | Replacement `instance-manager` pod scheduled on lenovo2 (~6-minute gap) |
| 19:14 | Host kernel marks 9 Longhorn-attached devices (`sde…sdl`) offline; EXT4 `JBD2` journals abort; `failed to convert unwritten extents — potential data loss` on inodes used by prometheus and postgres |
| 19:16 | New iSCSI sessions establish (`Power-on or device reset occurred`) — too late for the aborted journals |
| 19:26 | Second wave of `device offline` errors on `sdb sdc sdd`; filesystems unmounted |
| 19:28 | kubelet on lenovo2 stops posting node status — its KubePrism (`127.0.0.1:7445`) requests time out because the local apiserver/controller-manager/scheduler static pods are blocked on aborted-journal mounts; node goes `NotReady` |
| 21:18 | `talosctl reboot` issued; node kexecs and rejoins as `Ready` |

## Root cause

Cilium identity GC after the agent rollout left the longhorn-manager ↔
instance-manager grpc connection on lenovo2 stale. After ~90 minutes the
controller declared the instance-manager unreachable, marked all volumes
`unknown`, and recreated the pod. The recreation took ~6 minutes — well past
the kernel iSCSI initiator's `replacement_timeout` (120 s) — so every iSCSI
session held by the host kernel timed out and the EXT4 layer aborted the
journals before the new target came online.

The static control-plane pods on lenovo2 (kube-apiserver, controller-manager,
scheduler) write audit logs to a Longhorn-backed path; they hung on the
aborted mounts and never exited. Without a local apiserver, KubePrism on
lenovo2 had no healthy upstream within its timeout budget, so kubelet stopped
posting status and the node went `NotReady`.

The CLAUDE.md gotcha "after reinstalling Cilium, restart pods in other
namespaces — they get stale network identities" was followed for `argocd` but
not for `longhorn-system`. Storage-attached namespaces have a much narrower
safe-restart window: the restart must be staged per-node with the node drained
first, otherwise an uncontrolled `instance-manager` restart on a node still
holding attached volumes is exactly the failure that triggered this incident.

## What worked

- etcd quorum unaffected; cluster API stayed available throughout.
- Loki captured the longhorn-manager and kernel log streams pre-`NotReady`,
  giving us a clear timeline. The 2026-03-08 observability work paid off here.
- `talosctl reboot` via kexec recovered the node cleanly; no on-disk Longhorn
  data was lost (journal abort affected the host's view of the iSCSI block
  device, not the replicated Longhorn volume on backing disk).

## What didn't

- The post-Cilium runbook in CLAUDE.md only mentioned argocd and did not flag
  storage-attached namespaces as requiring drain-aware staging. Result: a
  known cascade went unmitigated.
- Volumes on lenovo2 were 2-replica (cluster default). The replica on
  lenovo1/lenovo3 kept serving for any pods still attached there, but pods
  with their attachment on lenovo2 were stuck Terminating until the reboot.

## Fix

This PR:

1. Tightens the "After reinstalling Cilium" guidance in CLAUDE.md to require
   a drain-aware, per-node restart for `longhorn-system`, with the explicit
   sequence (cordon → drain → restart longhorn pods on N → wait for volumes
   to settle → uncordon) before moving to the next node.
2. Lands this postmortem under `docs/plans/` so the trigger and the recovery
   procedure are discoverable from `git log`/grep.

Not in this PR (deferred):

- A `task day2:rollout-after-cilium` taskfile entry that automates the
  per-node drain-restart-uncordon loop. Cilium reinstalls are rare; the
  documented procedure is sufficient until we have evidence it isn't.
- Any change to Longhorn `defaultSettings`. The kernel `replacement_timeout`
  (120 s) was not the binding constraint — the gap was 6 minutes, so no
  realistic Longhorn timeout would have masked the cascade. Procedure, not
  configuration, is the right layer to fix this at.
