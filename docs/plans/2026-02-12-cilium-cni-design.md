# Cilium CNI Bootstrap Design

## Goal

Add Cilium as the CNI for the single-node Talos cluster, installed via Helm with kube-proxy replacement enabled. Designed so ArgoCD can adopt ownership of the Cilium Helm release later.

## Context

- Single-node Talos v1.12.3 cluster, Kubernetes v1.35.0
- No CNI currently configured (default Flannel is commented out in generated config)
- Existing Taskfile automation handles full Talos lifecycle
- Pod CIDR: `10.244.0.0/16`, Service CIDR: `10.96.0.0/12`
- KubePrism local API proxy enabled on port 7445

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Install method | Post-bootstrap Helm | Keeps Helm as source of truth; enables `helm upgrade` for day-2 ops and ArgoCD adoption later |
| Datapath mode | kube-proxy replacement (eBPF) | Better performance, fewer moving parts. Talos makes it easy to disable kube-proxy |
| Hubble | Disabled for now | Keep it lean; can enable later via values |
| Helm management | Single idempotent task (`helm upgrade --install`) | One command for both install and upgrade |
| App directory layout | `cluster/apps/<name>/` | Maps to future ArgoCD App-of-Apps pattern |
| Long-term ownership | ArgoCD (future) | Bootstrap via Taskfile, ArgoCD adopts later. No Helm release conflict since ArgoCD uses `helm template` + apply internally |

## Bootstrap Flow

```
task setup
  -> generate    (secrets + machine configs)
  -> patch       (apply all patches including cni.yaml)
  -> apply       (push config to node)
  -> bootstrap   (etcd init)
  -> kubeconfig  (retrieve kubeconfig)
  -> cilium      (helm upgrade --install)
```

## Changes

### New Files

#### `patches/cni.yaml`

Talos machine config patch to disable default Flannel and kube-proxy:

```yaml
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
```

#### `cluster/apps/cilium/values.yaml`

Cilium Helm values tuned for Talos:

- `kubeProxyReplacement: true` — full eBPF kube-proxy replacement
- `ipam.mode: kubernetes` — uses k8s-native IPAM, aligns with existing pod CIDR
- `cgroup.autoMount.enabled: false` — Talos mounts cgroups itself
- `cgroup.hostRoot: /sys/fs/cgroup` — Talos cgroup mount path
- `securityContext` — additional capabilities required on Talos (`SYS_PTRACE`, `SYS_RESOURCE`)
- `k8sServiceHost: localhost`, `k8sServicePort: 7445` — points at KubePrism to avoid circular dependency (Cilium needs API server, but networking isn't up yet)

### Modified Files

#### `Taskfile.yaml`

- New variable: `CILIUM_VERSION` (pinned alongside existing TALOS_VERSION and KUBERNETES_VERSION)
- New task: `cilium` — runs `helm upgrade --install cilium cilium/cilium --namespace kube-system --version $CILIUM_VERSION --values cluster/apps/cilium/values.yaml`
- Updated task: `patch` — also applies `patches/cni.yaml` to generated controlplane config
- Updated task: `setup` — adds `cilium` as the final step

## Day-2 Operations

### Cilium Upgrade

1. Bump `CILIUM_VERSION` in Taskfile.yaml
2. Update `cluster/apps/cilium/values.yaml` if needed
3. Run `task cilium`

### Future ArgoCD Adoption

When ArgoCD is added:
1. Bootstrap ArgoCD via Taskfile (same pattern as Cilium)
2. Create an ArgoCD Application pointing to `cluster/apps/cilium/` in the GitHub repo
3. ArgoCD adopts the existing Cilium resources by applying its tracking labels
4. Cilium upgrades then happen via git commits, ArgoCD reconciles
