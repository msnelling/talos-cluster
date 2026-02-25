# Multi-Node Cluster Expansion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Expand the single-node Talos cluster to 3 control plane nodes, with the existing node becoming controlplane-only and a VIP for the Kubernetes API endpoint.

**Architecture:** Add a `schedulable` field to node definitions in `vars.yaml`. A new Talos patch (`no-schedule.yaml`) applies a `NoSchedule` taint to nodes marked `schedulable: false`. A new day-2 task generates and applies configs for joining new nodes to an existing cluster. Cilium and Longhorn values update for multi-node HA.

**Tech Stack:** Talos Linux, Taskfile, Helm, yq, Cilium, Longhorn

**Design doc:** `docs/plans/2026-02-25-multi-node-expansion-design.md`

---

### Task 1: Create the NoSchedule taint patch

Creates the Talos machine config patch that prevents workload scheduling on a node.

**Files:**
- Create: `patches/no-schedule.yaml`

**Step 1: Create the patch file**

```yaml
machine:
  kubelet:
    extraConfig:
      registerWithTaints:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
```

**Step 2: Verify the patch is valid YAML**

Run: `yq e '.' patches/no-schedule.yaml`
Expected: The YAML is printed back without errors.

**Step 3: Commit**

```bash
git add patches/no-schedule.yaml
git commit -m "feat: add NoSchedule taint patch for controlplane-only nodes"
```

---

### Task 2: Update `_patch-node` to conditionally apply the taint

Reads the `schedulable` field from `vars.yaml` and includes the no-schedule patch when `false`.

**Files:**
- Modify: `taskfiles/setup.yaml:65-105` (`_patch-node` task)

**Step 1: Add `NODE_SCHEDULABLE` var to `_patch-node`**

In the `vars:` block of `_patch-node` (after `CONTROL_PLANE_VIP`), add:

```yaml
      NODE_SCHEDULABLE:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .schedulable // true' vars.yaml
```

**Step 2: Add conditional patch inclusion**

In the shell block that assembles `$PATCHES` (the last `cmds` entry of `_patch-node`), add this **before** the final `talosctl machineconfig patch` line:

```bash
        if [ "{{.NODE_SCHEDULABLE}}" = "false" ]; then
          PATCHES="$PATCHES --patch @patches/no-schedule.yaml"
        fi
```

Insert it after the VIP patch check (`if [ -f "generated/{{.NODE_NAME}}-vip-patch.yaml" ]`) and before the `talosctl machineconfig patch` line.

**Step 3: Verify the taskfile is valid**

Run: `task --list`
Expected: All tasks listed without parse errors.

**Step 4: Commit**

```bash
git add taskfiles/setup.yaml
git commit -m "feat: conditionally apply NoSchedule taint based on node schedulable field"
```

---

### Task 3: Create the `day2:join-node` task

A task for joining new nodes to an existing cluster. Reuses existing secrets, generates + patches config for one node, and applies it.

**Files:**
- Modify: `taskfiles/day2.yaml` (add `join-node` and `_join-single-node` tasks)

**Step 1: Add the `join-node` task**

Add the following to `taskfiles/day2.yaml` after the `upgrade-k8s` task:

```yaml
  join-node:
    desc: "Join a new node to the existing cluster (usage: task day2:join-node -- <node-name>)"
    deps: [":_require-nodes"]
    preconditions:
      - sh: '[ -n "{{.CLI_ARGS}}" ]'
        msg: "Usage: task day2:join-node -- <node-name>"
      - sh: yq -e '.nodes[] | select(.name == "{{.CLI_ARGS}}")' vars.yaml
        msg: "Node '{{.CLI_ARGS}}' not found in vars.yaml"
      - sh: '[ -f generated/secrets.yaml ]'
        msg: "generated/secrets.yaml not found. Run 'task setup' first on the initial node."
    vars:
      JOIN_NODE: "{{.CLI_ARGS}}"
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
    cmds:
      - echo "Generating config for {{.JOIN_NODE}} using existing cluster secrets..."
      - talosctl gen config
          --with-secrets generated/secrets.yaml
          --output generated/
          --force
          {{.CLUSTER_NAME}}
          https://{{.CONTROL_PLANE_ENDPOINT}}:{{.CONTROL_PLANE_PORT}}
      - yq -n '.machine.install.image = "factory.talos.dev/installer-secureboot/{{.SCHEMATIC_ID}}:{{.TALOS_VERSION}}"'
          > generated/install-image-patch.yaml
      - |
        yq -n '
          .apiVersion = "v1alpha1" |
          .kind = "ExtensionServiceConfig" |
          .name = "tailscale" |
          .environment = ["TS_AUTHKEY={{.TAILSCALE_AUTH_KEY}}"]
        ' > generated/tailscale-patch.yaml
        if [ -n "{{.TAILSCALE_ROUTES}}" ]; then
          yq -i '.environment += ["TS_ROUTES={{.TAILSCALE_ROUTES}}"]' generated/tailscale-patch.yaml
        fi
      - task: setup:_patch-node
        vars:
          NODE_NAME: "{{.JOIN_NODE}}"
      - task: _join-apply
        vars:
          NODE_NAME: "{{.JOIN_NODE}}"

  _join-apply:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "Applying config to {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl apply-config --insecure
          --nodes {{.NODE_IP}}
          --file generated/{{.NODE_NAME}}.yaml
      - echo "Config applied. {{.NODE_NAME}} will now install Talos and join the cluster."
      - echo "Monitor progress with: talosctl --context {{.CLUSTER_NAME}} --nodes {{.NODE_IP}} dmesg -f"
```

**Step 2: Verify the taskfile is valid**

Run: `task --list`
Expected: `day2:join-node` appears in the task list with its description.

**Step 3: Commit**

```bash
git add taskfiles/day2.yaml
git commit -m "feat: add day2:join-node task for joining new nodes to existing cluster"
```

---

### Task 4: Update `vars.yaml.example` with new fields

Document the `schedulable` field and show a multi-node example.

**Files:**
- Modify: `vars.yaml.example:5-15` (control_plane_vip and nodes section)

**Step 1: Update the example**

Replace the `nodes:` section with:

```yaml
control_plane_vip: ""          # Required if >1 control plane node

nodes:
  - name: node1
    ip: ""
    disk: /dev/sda
    interface: eno1
    schedulable: false           # Optional, defaults to true. Set false for controlplane-only.
  - name: node2
    ip: ""
    disk: /dev/sda
    interface: eno1
  # - name: node3
  #   ip: ""
  #   role: worker             # Optional, defaults to "controlplane"
  #   disk: /dev/sda
  #   interface: eno1
```

**Step 2: Commit**

```bash
git add vars.yaml.example
git commit -m "docs: add schedulable field and multi-node example to vars.yaml.example"
```

---

### Task 5: Update Cilium operator replicas

Increase Cilium operator replicas from 1 to 2 for HA.

**Files:**
- Modify: `cluster/apps/cilium/values.yaml:38` (operator.replicas)

**Step 1: Change replicas**

Change line 38 from:
```yaml
    replicas: 1
```
to:
```yaml
    replicas: 2
```

**Step 2: Validate the chart**

Run: `helm dependency build cluster/apps/cilium && helm lint cluster/apps/cilium`
Expected: `1 chart(s) linted, 0 chart(s) failed`

**Step 3: Commit**

```bash
git add cluster/apps/cilium/values.yaml
git commit -m "feat: increase Cilium operator replicas to 2 for multi-node HA"
```

---

### Task 6: Update Longhorn replica counts

Increase default replica count from 1 to 3 for data redundancy across all storage nodes.

**Files:**
- Modify: `cluster/apps/longhorn/values.yaml:12,19` (defaultReplicaCount, defaultClassReplicaCount)

**Step 1: Change replica counts**

Change `defaultSettings.defaultReplicaCount` (line 12) from `1` to `3`.
Change `persistence.defaultClassReplicaCount` (line 19) from `1` to `3`.

**Step 2: Validate the chart**

Run: `helm dependency build cluster/apps/longhorn && helm lint cluster/apps/longhorn`
Expected: `1 chart(s) linted, 0 chart(s) failed`

**Step 3: Commit**

```bash
git add cluster/apps/longhorn/values.yaml
git commit -m "feat: increase Longhorn replica count to 3 for multi-node redundancy"
```

---

### Task 7: Update CLAUDE.md

Update the project documentation to reflect the new `schedulable` field, the `join-node` task, and multi-node operational notes.

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add `join-node` to day-2 operations**

In the `### Day-2 Operations` section, add after the existing entries:

```bash
task day2:join-node -- <name>  # Join a new node to the existing cluster
```

**Step 2: Add note about `schedulable` field**

In the `### Configuration` section, after the sentence about roles, add:

> Set `schedulable: false` on a control plane node to apply a `NoSchedule` taint, preventing workload pods from being scheduled on it. Defaults to `true`.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add join-node task and schedulable field to CLAUDE.md"
```

---

### Task 8: Manual operator steps (reference — not automated)

These are the steps the operator runs after the code changes are pushed and new hardware is ready. This task is a reference checklist, not code to implement.

1. Boot new nodes from Talos ISO
2. Run `task utility:disks` and `task utility:links` to discover disk paths and interface names
3. Update `vars.yaml` with actual IPs, disks, interfaces for node2/node3, set `control_plane_vip`, set node1 `schedulable: false`
4. Run `task day2:join-node -- node2` then `task day2:join-node -- node3`
5. Wait for nodes to join: `kubectl get nodes --watch`
6. Run `task reconfigure` to apply VIP + taint patches to existing node1
7. Drain node1: `kubectl drain node1 --delete-emptydir-data --ignore-daemonsets`
8. Verify: `task utility:status`
9. Push Cilium + Longhorn value changes to git for ArgoCD to sync
