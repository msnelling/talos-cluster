# Multi-Node Cluster Expansion Design

**Date:** 2026-02-25
**Status:** Approved

## Summary

Expand the single-node Talos cluster to 3 control plane nodes. The existing node becomes controlplane-only (no workloads) via a NoSchedule taint. The two new nodes run both control plane and worker workloads. A Virtual IP provides a stable Kubernetes API endpoint.

## Context

The cluster currently runs a single control plane node with `allowSchedulingOnControlPlanes: true`, meaning it runs both control plane components and application workloads. Adding two more capable nodes improves availability and separates concerns: the original node focuses on control plane duties while the new nodes handle workloads.

This is a day-2 operation — nodes join the existing cluster, no rebuild required.

## Design

### 1. vars.yaml Schema Change

Add `schedulable` field to node definitions. Defaults to `true` when omitted (preserves current behavior).

```yaml
control_plane_vip: "<vip-ip>"

nodes:
  - name: node1
    ip: "<current-ip>"
    disk: /dev/sda
    interface: eno1
    schedulable: false    # controlplane-only
  - name: node2
    ip: "<tbd>"
    disk: "<tbd>"
    interface: "<tbd>"
  - name: node3
    ip: "<tbd>"
    disk: "<tbd>"
    interface: "<tbd>"
```

Update `vars.yaml.example` to document the new field.

### 2. NoSchedule Taint Patch

New file `patches/no-schedule.yaml`:

```yaml
machine:
  kubelet:
    extraConfig:
      registerWithTaints:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
```

Applied only to nodes where `schedulable: false`.

### 3. Setup Task Changes

In `_patch-node` (`taskfiles/setup.yaml`), read the `schedulable` field and conditionally include the no-schedule patch:

```bash
SCHEDULABLE=$(yq '... | .schedulable // true' vars.yaml)
if [ "$SCHEDULABLE" = "false" ]; then
  PATCHES="$PATCHES --patch @patches/no-schedule.yaml"
fi
```

### 4. VIP Handling

Already implemented. When `control_plane_vip` is set, `_patch-node` generates a VIP patch for each control plane node. The `generate` task uses VIP as the cluster endpoint. No changes needed.

### 5. Day-2 Join Task

New task `day2:join-node` that:
1. Reads existing cluster secrets from `generated/secrets.yaml`
2. Generates a config for the specified node using the existing secrets
3. Patches the config (common, VIP, install image, tailscale, no-schedule if applicable)
4. Applies the config to the new node via `talosctl apply-config --insecure`

This avoids regenerating secrets or touching existing nodes.

### 6. Cilium Operator Replicas

Increase from 1 to 2 for HA (max useful value — leader election means only one is active).

```yaml
# cluster/apps/cilium/values.yaml
operator:
  replicas: 2
```

### 7. Longhorn Replica Count

Increase default replica count from 1 to 3 for data redundancy across all storage nodes.

```yaml
# cluster/apps/longhorn/values.yaml
defaultSettings:
  defaultReplicaCount: 3
persistence:
  defaultClassReplicaCount: 3
```

### 8. Existing Node Reconfiguration

After new nodes join, run `task reconfigure` to apply VIP and taint patches to the existing node. The node reboots to pick up changes.

### 9. Workload Migration

After the existing node returns with the taint, run `kubectl drain` to migrate existing workloads to the new nodes. DaemonSets (Cilium, Longhorn, Tailscale) are unaffected by the taint.

### 10. Storage Continuity

The existing node keeps the Longhorn extra mount and continues participating in storage replication. Only application pod scheduling is prevented by the taint.

## Execution Order

1. Update `vars.yaml` with VIP and placeholder entries for new nodes
2. Update `vars.yaml.example` with new `schedulable` field documentation
3. Create `patches/no-schedule.yaml`
4. Update `taskfiles/setup.yaml` `_patch-node` to handle `schedulable` field
5. Create `day2:join-node` task in `taskfiles/day2.yaml`
6. Update Cilium values (operator replicas: 2)
7. Update Longhorn values (replica count: 3)
8. Commit and push all changes
9. Boot new nodes from Talos ISO, discover IPs/disks/interfaces
10. Update `vars.yaml` with actual node details
11. Run join task for each new node
12. Wait for nodes to join the cluster
13. Run `task reconfigure` to apply VIP + taint to existing node
14. Drain existing node to migrate workloads
15. Verify cluster health

## Decisions

- **Taint via Talos config** (not kubectl): Declarative, survives rebuilds, matches GitOps philosophy.
- **`allowSchedulingOnControlPlanes` stays true**: The two new nodes need it. The taint on node1 overrides it for that specific node.
- **Longhorn stays on all nodes**: More replicas for durability, existing node contributes storage capacity.
- **Same factory.yaml for all nodes**: Hardware is similar enough that the same Talos extensions apply.
