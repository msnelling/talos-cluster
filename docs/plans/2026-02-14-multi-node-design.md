# Multi-Node Support Design

## Goal

Update the single-node Talos cluster setup to support flexible topology: any combination of mixed control plane + worker nodes, from single-node to multi-node HA. A single-node cluster remains a one-element list — no breaking change in behavior.

## Decisions

- **Topology:** All nodes default to `controlplane` role (mixed mode, runs both control plane components and workloads via `allowSchedulingOnControlPlanes: true`). Optional `role: worker` for dedicated worker nodes.
- **Node config:** Structured YAML list in `vars.yaml` replaces the single `node_ip`, `disk`, `interface` fields.
- **HA endpoint:** Talos VIP — a floating IP shared between control plane nodes. Required when >1 CP. No external load balancer needed.
- **Bootstrap UX:** Single `task setup` provisions all defined nodes. No separate add-node workflow.
- **Day-2 operations:** Always operate on all nodes sequentially (rolling). No single-node targeting.
- **Single-node compat:** A one-element `nodes` list with no `control_plane_vip` behaves identically to today.

## vars.yaml Format

```yaml
cluster_name: lenovo
talos_version: v1.12.3
kubernetes_version: v1.35.0
control_plane_port: 6443
control_plane_vip: ""          # Required if >1 control plane node

nodes:
  - name: node1
    ip: "10.1.1.140"
    disk: /dev/sda
    interface: eno1
  - name: node2
    ip: "10.1.1.141"
    disk: /dev/sda
    interface: eno1
  # - name: node3
  #   ip: "10.1.1.142"
  #   role: worker             # Optional, defaults to "controlplane"
  #   disk: /dev/nvme0n1
  #   interface: eth0

# ... secrets unchanged
```

## Taskfile Variable Resolution

Replace single-node vars with helpers:

```yaml
vars:
  NODE_NAMES:
    sh: yq '.nodes[].name' vars.yaml
  CP_NAMES:
    sh: yq '[.nodes[] | select(.role == "worker" | not)] | .[].name' vars.yaml
  BOOTSTRAP_IP:
    sh: yq '[.nodes[] | select(.role == "worker" | not)][0].ip' vars.yaml
  CONTROL_PLANE_ENDPOINT:
    sh: |
      vip=$(yq '.control_plane_vip // ""' vars.yaml)
      if [ -n "$vip" ]; then echo "$vip"
      else yq '[.nodes[] | select(.role == "worker" | not)][0].ip' vars.yaml
      fi
  NODE_COUNT:
    sh: yq '.nodes | length' vars.yaml
  CP_COUNT:
    sh: yq '[.nodes[] | select(.role == "worker" | not)] | length' vars.yaml
  ALL_CP_IPS:
    sh: yq '[.nodes[] | select(.role == "worker" | not) | .ip] | join(" ")' vars.yaml
```

Removed: `NODE_IP`, `set-node` task. `_require-node-ip` replaced with `_require-nodes`.

## Iteration Pattern

Uses Taskfile native `for` loops (v3.28.0+) with internal sub-tasks:

```yaml
apply:
  cmds:
    - for: { var: NODE_NAMES, as: NODE }
      task: _apply-node
      vars:
        NODE_NAME: "{{ .NODE }}"

_apply-node:
  internal: true
  vars:
    NODE_IP:
      sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
  cmds:
    - talosctl apply-config --insecure --nodes {{.NODE_IP}} --file generated/{{.NODE_NAME}}.yaml
```

## Setup Flow

### generate (internal)
1. `mkdir -p generated/`
2. Generate cluster-wide secrets: `talosctl gen secrets -o generated/secrets.yaml`
3. Generate configs with `CONTROL_PLANE_ENDPOINT`: produces `generated/controlplane.yaml` and `generated/worker.yaml` as templates
4. Set talosconfig endpoints to all CP IPs
5. Set talosconfig node to `BOOTSTRAP_IP`
6. Merge talosconfig

Precondition: if >1 CP node, `control_plane_vip` must be set.

### patch (internal)
For each node:
1. Determine source template (`controlplane.yaml` or `worker.yaml` based on role)
2. Generate per-node patches (disk, interface, install image, tailscale)
3. If VIP is set: generate VIP patch (applied to CP nodes only)
4. Apply patches: `talosctl machineconfig patch ... --output generated/$NODE_NAME.yaml`

### apply (user-facing)
For each node: `talosctl apply-config --insecure --nodes $IP --file generated/$NODE_NAME.yaml`

### Top-level setup
1. `setup:generate`
2. `setup:patch`
3. `setup:apply`
4. Prompt to remove bootable media
5. Wait for Talos API on `BOOTSTRAP_IP`
6. `setup:bootstrap` (targets `BOOTSTRAP_IP` only)
7. Wait for all nodes to join (`kubectl get nodes` until `NODE_COUNT` seen)
8. `setup:kubeconfig`
9. Components: cilium, traefik, cert-manager, longhorn-secret, argocd
10. `talosctl health`

### reconfigure
1. `setup:patch` (regenerates per-node configs)
2. For each node: `talosctl apply-config --context $CLUSTER --file generated/$NODE_NAME.yaml --nodes $IP`

## Generated File Layout

```
generated/
  secrets.yaml          # Cluster-wide
  talosconfig           # Cluster-wide
  controlplane.yaml     # Template (intermediate)
  worker.yaml           # Template (intermediate)
  node1.yaml            # Final patched config for node1
  node2.yaml            # Final patched config for node2
```

## Talos VIP Patch

Generated only when `control_plane_vip` is set, applied only to CP nodes:

```yaml
machine:
  network:
    interfaces:
      - interface: <node's interface>
        vip:
          ip: <control_plane_vip>
```

## Day-2 Operations

All tasks loop over all nodes sequentially:

- **upgrade-talos:** Rolling `talosctl upgrade` per node (waits for each to rejoin)
- **upgrade-k8s:** Single cluster-wide `talosctl upgrade-k8s` (no iteration)
- **reboot:** Rolling `talosctl reboot` per node (waits for each to come back)
- **reset:** Rolling `talosctl reset` per node (still prompts for confirmation)

## Utility Tasks

- **status:** Cluster-wide commands, no iteration needed
- **dashboard:** Uses talosctl context, no change
- **disks, links:** Loop over all nodes with `--insecure --nodes $IP`

## Task Visibility

| Task | Visibility |
|------|-----------|
| `setup:download` | user-facing |
| `setup:generate` | internal |
| `setup:patch` | internal |
| `setup:apply` | user-facing |
| `setup:bootstrap` | internal |
| `setup:kubeconfig` | user-facing |

## What Does NOT Change

- **`patches/*`** — same patches, applied conditionally per role
- **`cluster/apps/*`** — all Helm charts already multi-node ready
- **`cluster/lib/*`** — library chart unchanged
- **`cluster/db3000/*`** — media apps unchanged
- **`taskfiles/components.yaml`** — Helm installs are cluster-wide
- **`factory.yaml`** — same Talos image for all nodes
- **Cilium, Longhorn, Traefik values** — replica counts are storage/HA policy, not setup concerns
