# Multi-Node Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Update the Taskfile orchestration and vars format to support multiple Talos nodes with flexible topology (mixed control plane + worker).

**Architecture:** Replace single `node_ip` with a `nodes:` list in `vars.yaml`. Taskfile tasks iterate over nodes using native `for` loops with internal sub-tasks. Talos VIP provides HA control plane endpoint when multiple CP nodes are defined. Single-node clusters are a one-element list — no behavioral change.

**Tech Stack:** Taskfile v3.48, yq, talosctl, Helm

**Design doc:** `docs/plans/2026-02-14-multi-node-design.md`

---

### Task 1: Update vars.yaml.example

**Files:**
- Modify: `vars.yaml.example`

**Step 1: Replace single-node fields with nodes list**

Replace the entire file with:

```yaml
cluster_name: lenovo
talos_version: v1.12.3
kubernetes_version: v1.35.0
control_plane_port: 6443
control_plane_vip: ""          # Required if >1 control plane node

nodes:
  - name: node1
    ip: ""
    disk: /dev/sda
    interface: eno1
  # - name: node2
  #   ip: ""
  #   role: worker             # Optional, defaults to "controlplane"
  #   disk: /dev/sda
  #   interface: eno1

tailscale_auth_key: "tskey-auth-..."
tailscale_routes: "10.1.1.0/24"
loadbalancer_ip: "10.1.1.60"
domain: "example.com"
cloudflare_api_token: "your-cloudflare-api-token"
longhorn_s3_endpoint: "https://truenas.local:9000"
longhorn_s3_access_key: "your-minio-access-key"
longhorn_s3_secret_key: "your-minio-secret-key"

# db3000 media apps
smb_username: "your-smb-username"
smb_password: "your-smb-password"
vpn_service_provider: "mullvad"
vpn_type: "wireguard"
vpn_wireguard_private_key: "your-wireguard-private-key"
vpn_wireguard_addresses: "your-wireguard-addresses"
vpn_server_cities: "your-server-cities"
vpn_proxy_user: "your-proxy-user"
vpn_proxy_password: "your-proxy-password"
vpn_auth_config: "your-gluetun-auth-config-toml"
```

Key changes from original:
- Removed: `node_ip`, `disk`, `interface` (top-level)
- Added: `control_plane_vip`, `nodes` list
- Each node has: `name`, `ip`, `disk`, `interface`, optional `role` (defaults to `controlplane`)

**Step 2: Commit**

```bash
git add vars.yaml.example
git commit -m "Update vars.yaml.example for multi-node support"
```

---

### Task 2: Update Taskfile.yaml — Variables and Helpers

**Files:**
- Modify: `Taskfile.yaml`

**Step 1: Replace single-node vars with multi-node vars**

Replace lines 15-55 (the `vars:` block) with:

```yaml
vars:
  CLUSTER_NAME:
    sh: yq '.cluster_name' vars.yaml
  TALOS_VERSION:
    sh: yq '.talos_version' vars.yaml
  KUBERNETES_VERSION:
    sh: yq '.kubernetes_version' vars.yaml
  CONTROL_PLANE_PORT:
    sh: yq '.control_plane_port' vars.yaml
  TAILSCALE_AUTH_KEY:
    sh: yq '.tailscale_auth_key' vars.yaml
  TAILSCALE_ROUTES:
    sh: yq '.tailscale_routes // ""' vars.yaml
  CLOUDFLARE_API_TOKEN:
    sh: yq '.cloudflare_api_token' vars.yaml
  LONGHORN_S3_ENDPOINT:
    sh: yq '.longhorn_s3_endpoint' vars.yaml
  LONGHORN_S3_ACCESS_KEY:
    sh: yq '.longhorn_s3_access_key' vars.yaml
  LONGHORN_S3_SECRET_KEY:
    sh: yq '.longhorn_s3_secret_key' vars.yaml
  SMB_USERNAME:
    sh: yq '.smb_username' vars.yaml
  SMB_PASSWORD:
    sh: yq '.smb_password' vars.yaml
  VPN_SERVICE_PROVIDER:
    sh: yq '.vpn_service_provider' vars.yaml
  VPN_TYPE:
    sh: yq '.vpn_type' vars.yaml
  VPN_WIREGUARD_PRIVATE_KEY:
    sh: yq '.vpn_wireguard_private_key' vars.yaml
  VPN_WIREGUARD_ADDRESSES:
    sh: yq '.vpn_wireguard_addresses' vars.yaml
  VPN_SERVER_CITIES:
    sh: yq '.vpn_server_cities' vars.yaml
  VPN_PROXY_USER:
    sh: yq '.vpn_proxy_user' vars.yaml
  VPN_PROXY_PASSWORD:
    sh: yq '.vpn_proxy_password' vars.yaml
  # Multi-node helpers
  NODE_NAMES:
    sh: yq '.nodes[].name' vars.yaml
  CP_NAMES:
    sh: yq '[.nodes[] | select(.role == "worker" | not)] | .[].name' vars.yaml
  NODE_COUNT:
    sh: yq '.nodes | length' vars.yaml
  CP_COUNT:
    sh: yq '[.nodes[] | select(.role == "worker" | not)] | length' vars.yaml
  BOOTSTRAP_IP:
    sh: yq '[.nodes[] | select(.role == "worker" | not)][0].ip' vars.yaml
  ALL_CP_IPS:
    sh: yq '[.nodes[] | select(.role == "worker" | not) | .ip] | join(" ")' vars.yaml
  CONTROL_PLANE_ENDPOINT:
    sh: |
      vip=$(yq '.control_plane_vip // ""' vars.yaml)
      if [ -n "$vip" ]; then echo "$vip"
      else yq '[.nodes[] | select(.role == "worker" | not)][0].ip' vars.yaml
      fi
```

Changes: removed `NODE_IP`. Added `NODE_NAMES`, `CP_NAMES`, `NODE_COUNT`, `CP_COUNT`, `BOOTSTRAP_IP`, `ALL_CP_IPS`, `CONTROL_PLANE_ENDPOINT`.

**Step 2: Replace `_require-node-ip` with `_require-nodes` and remove `set-node`**

Replace the `_require-node-ip` task (lines 63-67) with:

```yaml
  _require-nodes:
    internal: true
    preconditions:
      - sh: '[ "$(yq ".nodes | length" vars.yaml)" -gt 0 ]'
        msg: "No nodes defined in vars.yaml. Add at least one node to the nodes list."
```

Remove the `set-node` task entirely (lines 75-82).

**Step 3: Update `setup` task**

Replace the `setup` task (lines 84-107) with:

```yaml
  setup:
    desc: "Full initial setup: generate, patch, apply, bootstrap, kubeconfig"
    deps: [_require-nodes]
    interactive: true
    cmds:
      - task: setup:generate
      - task: setup:patch
      - task: setup:apply
      - read -rp "Remove the bootable ISO/USB from all nodes and press Enter to continue..."
      - |
        echo "Waiting for Talos API on bootstrap node ({{.BOOTSTRAP_IP}})..."
        until talosctl --context {{.CLUSTER_NAME}} version >/dev/null 2>&1; do sleep 5; done
        echo "Talos API is up."
      - task: setup:bootstrap
      - |
        echo "Waiting for all {{.NODE_COUNT}} node(s) to join..."
        until [ "$(kubectl --context admin@{{.CLUSTER_NAME}} get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "{{.NODE_COUNT}}" ]; do sleep 5; done
        echo "All nodes have joined."
      - task: setup:kubeconfig
      - task: components:cilium
      - task: components:traefik
      - task: components:cert-manager
      - task: components:longhorn-secret
      - task: components:argocd
      - echo "Waiting for cluster health..."
      - talosctl health --context {{.CLUSTER_NAME}} --wait-timeout 5m
      - 'echo "Cluster is ready. Verify with: kubectl --context admin@{{.CLUSTER_NAME}} get nodes"'
```

**Step 4: Update `reconfigure` task**

Replace the `reconfigure` task (lines 109-114) with:

```yaml
  reconfigure:
    desc: Re-patch and apply config changes (edit patches first, then run this)
    deps: [_require-nodes]
    cmds:
      - task: setup:patch
      - for: { var: NODE_NAMES, as: NODE }
        task: setup:_reconfigure-node
        vars:
          NODE_NAME: "{{ .NODE }}"
```

**Step 5: Commit**

```bash
git add Taskfile.yaml
git commit -m "Update Taskfile.yaml vars and helpers for multi-node"
```

---

### Task 3: Update taskfiles/setup.yaml — Generate and Bootstrap

**Files:**
- Modify: `taskfiles/setup.yaml`

**Step 1: Rewrite `generate` task**

Replace the `generate` task (lines 17-37) with:

```yaml
  generate:
    internal: true
    deps: [":_require-nodes"]
    preconditions:
      - sh: |
          cp_count=$(yq '[.nodes[] | select(.role == "worker" | not)] | length' vars.yaml)
          vip=$(yq '.control_plane_vip // ""' vars.yaml)
          [ "$cp_count" -le 1 ] || [ -n "$vip" ]
        msg: "control_plane_vip is required when defining multiple control plane nodes"
    cmds:
      - mkdir -p generated
      - talosctl gen secrets -o generated/secrets.yaml --force
      - talosctl gen config
          --with-secrets generated/secrets.yaml
          --output generated/
          --force
          {{.CLUSTER_NAME}}
          https://{{.CONTROL_PLANE_ENDPOINT}}:{{.CONTROL_PLANE_PORT}}
      - talosctl --talosconfig generated/talosconfig
          config endpoint {{.ALL_CP_IPS}}
      - talosctl --talosconfig generated/talosconfig
          config node {{.BOOTSTRAP_IP}}
      - |
        if [ -f ~/.talos/config ]; then
          yq -i 'del(.contexts.{{.CLUSTER_NAME}})' ~/.talos/config
        fi
      - talosctl config merge generated/talosconfig
```

Key changes:
- `deps` uses `_require-nodes` instead of `_require-node-ip`
- Precondition: VIP required when >1 CP
- Endpoint uses `CONTROL_PLANE_ENDPOINT` (VIP or first CP IP)
- talosconfig endpoint set to `ALL_CP_IPS` (space-separated, talosctl accepts multiple)
- talosconfig node set to `BOOTSTRAP_IP`

**Step 2: Update `bootstrap` task**

Replace the `bootstrap` task (lines 83-87) with:

```yaml
  bootstrap:
    internal: true
    deps: [":_require-nodes"]
    cmds:
      - echo "Bootstrapping cluster on {{.BOOTSTRAP_IP}}..."
      - talosctl bootstrap --context {{.CLUSTER_NAME}}
```

**Step 3: Update `kubeconfig` task**

Replace the `kubeconfig` task (lines 89-93) with:

```yaml
  kubeconfig:
    desc: Retrieve kubeconfig and merge into ~/.kube/config
    deps: [":_require-nodes"]
    cmds:
      - talosctl kubeconfig --context {{.CLUSTER_NAME}}
```

**Step 4: Commit**

```bash
git add taskfiles/setup.yaml
git commit -m "Update setup generate, bootstrap, kubeconfig for multi-node"
```

---

### Task 4: Update taskfiles/setup.yaml — Patch (Per-Node Config Generation)

**Files:**
- Modify: `taskfiles/setup.yaml`

This is the most complex change. The `patch` task becomes an orchestrator that loops over nodes, calling a per-node internal sub-task.

**Step 1: Replace `patch` task with orchestrator + sub-task**

Replace the `patch` task (lines 39-73) with:

```yaml
  patch:
    internal: true
    vars:
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
    cmds:
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
      - for: { var: NODE_NAMES, as: NODE }
        task: _patch-node
        vars:
          NODE_NAME: "{{ .NODE }}"

  _patch-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
      NODE_DISK:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .disk' vars.yaml
      NODE_INTERFACE:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .interface' vars.yaml
      NODE_ROLE:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .role // "controlplane"' vars.yaml
      CONTROL_PLANE_VIP:
        sh: yq '.control_plane_vip // ""' vars.yaml
    cmds:
      - echo "Patching config for {{.NODE_NAME}} ({{.NODE_IP}}, {{.NODE_ROLE}})..."
      - yq -n '
          .machine.install.disk = "{{.NODE_DISK}}" |
          .machine.network.interfaces[0].interface = "{{.NODE_INTERFACE}}" |
          .machine.network.interfaces[0].dhcp = true
        ' > generated/{{.NODE_NAME}}-common-patch.yaml
      - |
        if [ "{{.NODE_ROLE}}" != "worker" ] && [ -n "{{.CONTROL_PLANE_VIP}}" ]; then
          yq -n '
            .machine.network.interfaces[0].interface = "{{.NODE_INTERFACE}}" |
            .machine.network.interfaces[0].vip.ip = "{{.CONTROL_PLANE_VIP}}"
          ' > generated/{{.NODE_NAME}}-vip-patch.yaml
        fi
      - |
        SOURCE="generated/controlplane.yaml"
        if [ "{{.NODE_ROLE}}" = "worker" ]; then
          SOURCE="generated/worker.yaml"
        fi
        PATCHES="--patch @patches/cni.yaml --patch @patches/longhorn.yaml"
        if [ "{{.NODE_ROLE}}" != "worker" ]; then
          PATCHES="--patch @patches/controlplane.yaml $PATCHES"
        fi
        PATCHES="$PATCHES --patch @generated/{{.NODE_NAME}}-common-patch.yaml"
        PATCHES="$PATCHES --patch @generated/install-image-patch.yaml"
        PATCHES="$PATCHES --patch @generated/tailscale-patch.yaml"
        if [ -f "generated/{{.NODE_NAME}}-vip-patch.yaml" ]; then
          PATCHES="$PATCHES --patch @generated/{{.NODE_NAME}}-vip-patch.yaml"
        fi
        eval talosctl machineconfig patch "$SOURCE" $PATCHES --output generated/{{.NODE_NAME}}.yaml
```

Key design:
- Shared patches (install-image, tailscale) generated once in `patch`
- Per-node patches (common, vip) generated in `_patch-node`
- Source template selected by role: `controlplane.yaml` or `worker.yaml`
- `controlplane.yaml` patch only applied to CP nodes
- VIP patch only generated when `control_plane_vip` is set and node is CP

**Step 2: Commit**

```bash
git add taskfiles/setup.yaml
git commit -m "Add per-node patch generation with for loop"
```

---

### Task 5: Update taskfiles/setup.yaml — Apply and Reconfigure

**Files:**
- Modify: `taskfiles/setup.yaml`

**Step 1: Rewrite `apply` task with per-node iteration**

Replace the `apply` task (lines 75-81) with:

```yaml
  apply:
    desc: Apply config to all nodes (insecure, for first install)
    deps: [":_require-nodes"]
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
      - echo "Applying config to {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl apply-config --insecure
          --nodes {{.NODE_IP}}
          --file generated/{{.NODE_NAME}}.yaml
```

**Step 2: Add `_reconfigure-node` sub-task**

Add this after the `_apply-node` task (called from `reconfigure` in root Taskfile):

```yaml
  _reconfigure-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "Reconfiguring {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl apply-config
          --context {{.CLUSTER_NAME}}
          --nodes {{.NODE_IP}}
          --file generated/{{.NODE_NAME}}.yaml
```

**Step 3: Commit**

```bash
git add taskfiles/setup.yaml
git commit -m "Add per-node apply and reconfigure sub-tasks"
```

---

### Task 6: Update taskfiles/day2.yaml

**Files:**
- Modify: `taskfiles/day2.yaml`

**Step 1: Replace entire file**

```yaml
version: "3"

tasks:

  upgrade-talos:
    desc: Upgrade Talos OS on all nodes (rolling)
    deps: [":_require-nodes"]
    vars:
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
    cmds:
      - for: { var: NODE_NAMES, as: NODE }
        task: _upgrade-talos-node
        vars:
          NODE_NAME: "{{ .NODE }}"
          SCHEMATIC_ID: "{{.SCHEMATIC_ID}}"

  _upgrade-talos-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "Upgrading Talos on {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl upgrade
          --context {{.CLUSTER_NAME}}
          --nodes {{.NODE_IP}}
          --image "factory.talos.dev/installer-secureboot/{{.SCHEMATIC_ID}}:{{.TALOS_VERSION}}"

  upgrade-k8s:
    desc: Upgrade Kubernetes version (cluster-wide)
    deps: [":_require-nodes"]
    cmds:
      - talosctl upgrade-k8s
          --context {{.CLUSTER_NAME}}
          --to {{.KUBERNETES_VERSION}}

  reboot:
    desc: Reboot all nodes (rolling)
    deps: [":_require-nodes"]
    cmds:
      - for: { var: NODE_NAMES, as: NODE }
        task: _reboot-node
        vars:
          NODE_NAME: "{{ .NODE }}"

  _reboot-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "Rebooting {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl reboot
          --context {{.CLUSTER_NAME}}
          --nodes {{.NODE_IP}}

  reset:
    desc: Wipe all nodes and start over (DESTRUCTIVE)
    prompt: This will WIPE ALL NODES and destroy all data. Are you sure?
    deps: [":_require-nodes"]
    cmds:
      - for: { var: NODE_NAMES, as: NODE }
        task: _reset-node
        vars:
          NODE_NAME: "{{ .NODE }}"

  _reset-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "Resetting {{.NODE_NAME}} ({{.NODE_IP}})..."
      - talosctl reset
          --context {{.CLUSTER_NAME}}
          --nodes {{.NODE_IP}}
          --graceful=false
          --reboot
```

Key changes:
- All tasks use `_require-nodes` instead of `_require-node-ip`
- `upgrade-talos`, `reboot`, `reset` iterate over all nodes via `for` + internal sub-tasks
- `upgrade-k8s` stays cluster-wide (no iteration)
- Each sub-task resolves its own `NODE_IP` via yq lookup
- `upgrade-talos` passes `SCHEMATIC_ID` through to sub-task (computed once)
- `reset` prompt updated to say "ALL NODES"

**Step 2: Commit**

```bash
git add taskfiles/day2.yaml
git commit -m "Update day2 tasks for rolling multi-node operations"
```

---

### Task 7: Update taskfiles/utility.yaml

**Files:**
- Modify: `taskfiles/utility.yaml`

**Step 1: Replace entire file**

```yaml
version: "3"

tasks:

  status:
    desc: Show cluster health and node status
    deps: [":_require-nodes"]
    preconditions:
      - sh: command -v cilium
        msg: "cilium CLI is required. Install with: brew install cilium-cli"
    cmds:
      - talosctl health --context {{.CLUSTER_NAME}}
      - kubectl --context admin@{{.CLUSTER_NAME}} get nodes -o wide
      - cilium status --context admin@{{.CLUSTER_NAME}}

  dashboard:
    desc: Open Talos dashboard
    deps: [":_require-nodes"]
    interactive: true
    cmds:
      - talosctl dashboard --context {{.CLUSTER_NAME}}

  disks:
    desc: List disks on all nodes (useful before first install)
    deps: [":_require-nodes"]
    cmds:
      - for: { var: NODE_NAMES, as: NODE }
        task: _disks-node
        vars:
          NODE_NAME: "{{ .NODE }}"

  _disks-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "=== {{.NODE_NAME}} ({{.NODE_IP}}) ==="
      - talosctl get disks --insecure --nodes {{.NODE_IP}}

  links:
    desc: List network interfaces on all nodes
    deps: [":_require-nodes"]
    cmds:
      - for: { var: NODE_NAMES, as: NODE }
        task: _links-node
        vars:
          NODE_NAME: "{{ .NODE }}"

  _links-node:
    internal: true
    vars:
      NODE_IP:
        sh: yq '.nodes[] | select(.name == "{{.NODE_NAME}}") | .ip' vars.yaml
    cmds:
      - echo "=== {{.NODE_NAME}} ({{.NODE_IP}}) ==="
      - talosctl get links --insecure --nodes {{.NODE_IP}}
```

Key changes:
- All tasks use `_require-nodes` instead of `_require-node-ip`
- `status` and `dashboard` unchanged (already cluster-wide)
- `disks` and `links` iterate over all nodes via `for` + sub-tasks

**Step 2: Commit**

```bash
git add taskfiles/utility.yaml
git commit -m "Update utility tasks for multi-node iteration"
```

---

### Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the Commands > Bootstrap section**

Replace:
```markdown
### Bootstrap
\```bash
task setup NODE_IP=x.x.x.x    # Full cluster bootstrap (generate → patch → apply → bootstrap → install all components)
\```
```

With:
```markdown
### Bootstrap
\```bash
task setup    # Full cluster bootstrap for all nodes defined in vars.yaml
\```
```

**Step 2: Update the Commands > Individual Component Install/Upgrade section**

No changes needed — component tasks are cluster-wide.

**Step 3: Update the Commands > Day-2 Operations section**

Replace:
```markdown
### Day-2 Operations
\```bash
task day2:upgrade-talos   # Upgrade Talos OS
task day2:upgrade-k8s     # Upgrade Kubernetes
task day2:reboot          # Reboot the node
task day2:reset           # Wipe the node (DESTRUCTIVE, prompts for confirmation)
task reconfigure          # Re-patch and apply Talos config changes (top-level wrapper)
\```
```

With:
```markdown
### Day-2 Operations
\```bash
task day2:upgrade-talos   # Rolling Talos upgrade across all nodes
task day2:upgrade-k8s     # Upgrade Kubernetes (cluster-wide)
task day2:reboot          # Rolling reboot across all nodes
task day2:reset           # Wipe all nodes (DESTRUCTIVE, prompts for confirmation)
task reconfigure          # Re-patch and apply Talos config changes to all nodes
\```
```

**Step 4: Update the Configuration section**

Replace the paragraph about `vars.yaml`:
```markdown
`vars.yaml` (git-ignored) holds cluster config: node IP, Talos/K8s versions, and secrets. See `vars.yaml.example` for structure. Helm chart versions are pinned in each app's `Chart.yaml`, not in `vars.yaml`.
```

With:
```markdown
`vars.yaml` (git-ignored) holds cluster config: node list (name, IP, role, disk, interface), Talos/K8s versions, optional control plane VIP, and secrets. See `vars.yaml.example` for structure. Nodes default to `controlplane` role (mixed mode — runs both control plane and workloads). Set `role: worker` for dedicated worker nodes. Set `control_plane_vip` when using multiple control plane nodes. Helm chart versions are pinned in each app's `Chart.yaml`, not in `vars.yaml`.
```

**Step 5: Update the Critical Gotchas section**

Add this entry:

```markdown
**Multi-node control plane requires `control_plane_vip`** in `vars.yaml`. This enables Talos's built-in Virtual IP for the Kubernetes API endpoint. Single control plane nodes don't need it — the endpoint falls back to the node's IP.
```

**Step 6: Remove references to `NODE_IP` parameter**

Search for any remaining `NODE_IP` references in CLAUDE.md and update them. The `set-node` task no longer exists.

**Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md for multi-node support"
```

---

### Task 9: Validate Taskfile Syntax

**Step 1: Run task --list to verify no syntax errors**

```bash
task --list
```

Expected: All tasks listed without errors. No `set-node` task. No references to `NODE_IP` in task names or descriptions.

**Step 2: Verify yq expressions work with example format**

Create a temporary test:
```bash
# Create a temp vars with the new format to test yq expressions
cat <<'EOF' > /tmp/test-vars.yaml
nodes:
  - name: node1
    ip: "10.1.1.140"
    disk: /dev/sda
    interface: eno1
  - name: node2
    ip: "10.1.1.141"
    disk: /dev/nvme0n1
    interface: eth0
    role: worker
control_plane_vip: "10.1.1.50"
EOF

echo "NODE_NAMES:"
yq '.nodes[].name' /tmp/test-vars.yaml

echo "CP_NAMES:"
yq '[.nodes[] | select(.role == "worker" | not)] | .[].name' /tmp/test-vars.yaml

echo "BOOTSTRAP_IP:"
yq '[.nodes[] | select(.role == "worker" | not)][0].ip' /tmp/test-vars.yaml

echo "ALL_CP_IPS:"
yq '[.nodes[] | select(.role == "worker" | not) | .ip] | join(" ")' /tmp/test-vars.yaml

echo "CONTROL_PLANE_ENDPOINT:"
vip=$(yq '.control_plane_vip // ""' /tmp/test-vars.yaml)
if [ -n "$vip" ]; then echo "$vip"
else yq '[.nodes[] | select(.role == "worker" | not)][0].ip' /tmp/test-vars.yaml
fi

echo "NODE_COUNT:"
yq '.nodes | length' /tmp/test-vars.yaml

echo "CP_COUNT:"
yq '[.nodes[] | select(.role == "worker" | not)] | length' /tmp/test-vars.yaml

rm /tmp/test-vars.yaml
```

Expected output:
```
NODE_NAMES:
node1
node2
CP_NAMES:
node1
BOOTSTRAP_IP:
10.1.1.140
ALL_CP_IPS:
10.1.1.140
CONTROL_PLANE_ENDPOINT:
10.1.1.50
NODE_COUNT:
2
CP_COUNT:
1
```

**Step 3: Test single-node fallback**

```bash
cat <<'EOF' > /tmp/test-vars-single.yaml
nodes:
  - name: node1
    ip: "10.1.1.140"
    disk: /dev/sda
    interface: eno1
EOF

echo "CONTROL_PLANE_ENDPOINT (no VIP):"
vip=$(yq '.control_plane_vip // ""' /tmp/test-vars-single.yaml)
if [ -n "$vip" ]; then echo "$vip"
else yq '[.nodes[] | select(.role == "worker" | not)][0].ip' /tmp/test-vars-single.yaml
fi

rm /tmp/test-vars-single.yaml
```

Expected: `10.1.1.140` (falls back to first CP IP when no VIP set).

**Step 4: Commit validation results (if any fixes needed)**
