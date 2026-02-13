# Taskfile Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split the monolithic `Taskfile.yaml` into 4 domain-grouped files under `taskfiles/` with namespaced includes.

**Architecture:** Root `Taskfile.yaml` becomes a thin entry point (vars, helpers, includes, top-level wrappers). Domain files live in `taskfiles/`. Cross-file references use Taskfile's `:namespace:task` syntax.

**Tech Stack:** Taskfile v3, YAML

**Design doc:** `docs/plans/2026-02-13-taskfile-split-design.md`

---

### Task 1: Create `taskfiles/setup.yaml`

**Files:**
- Create: `taskfiles/setup.yaml`

**Step 1: Create the file**

```yaml
version: "3"

tasks:

  download:
    desc: Download Talos secure-boot ISO from Image Factory
    vars:
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
    cmds:
      - mkdir -p downloads
      - 'echo "Schematic ID: {{.SCHEMATIC_ID}}"'
      - curl -Lo downloads/metal-amd64-secureboot.iso
          "https://factory.talos.dev/image/{{.SCHEMATIC_ID}}/{{.TALOS_VERSION}}/metal-amd64-secureboot.iso"
      - echo "Downloaded downloads/metal-amd64-secureboot.iso"

  generate:
    internal: true
    deps: [:_require-node-ip]
    cmds:
      - mkdir -p generated
      - talosctl gen secrets -o generated/secrets.yaml --force
      - talosctl gen config
          --with-secrets generated/secrets.yaml
          --output generated/
          --force
          {{.CLUSTER_NAME}}
          https://{{.NODE_IP}}:{{.CONTROL_PLANE_PORT}}
      - talosctl --talosconfig generated/talosconfig
          config endpoint {{.NODE_IP}}
      - talosctl --talosconfig generated/talosconfig
          config node {{.NODE_IP}}
      - |
        if [ -f ~/.talos/config ]; then
          yq -i 'del(.contexts.{{.CLUSTER_NAME}})' ~/.talos/config
        fi
      - talosctl config merge generated/talosconfig

  patch:
    internal: true
    vars:
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
      DISK:
        sh: yq '.disk' vars.yaml
      INTERFACE:
        sh: yq '.interface' vars.yaml
    cmds:
      - yq -n '.machine.install.image = "factory.talos.dev/installer-secureboot/{{.SCHEMATIC_ID}}:{{.TALOS_VERSION}}"'
          > generated/install-image-patch.yaml
      - yq -n '
          .machine.install.disk = "{{.DISK}}" |
          .machine.network.interfaces[0].interface = "{{.INTERFACE}}" |
          .machine.network.interfaces[0].dhcp = true
        ' > generated/common-patch.yaml
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
      - talosctl machineconfig patch generated/controlplane.yaml
          --patch @patches/controlplane.yaml
          --patch @patches/cni.yaml
          --patch @patches/longhorn.yaml
          --patch @generated/common-patch.yaml
          --patch @generated/install-image-patch.yaml
          --patch @generated/tailscale-patch.yaml
          --output generated/controlplane.yaml

  apply:
    desc: Apply config to the node (insecure, for first install)
    deps: [:_require-node-ip]
    cmds:
      - talosctl apply-config --insecure
          --nodes {{.NODE_IP}}
          --file generated/controlplane.yaml

  bootstrap:
    internal: true
    deps: [:_require-node-ip]
    cmds:
      - talosctl bootstrap
          --context {{.CLUSTER_NAME}}

  kubeconfig:
    desc: Retrieve kubeconfig and merge into ~/.kube/config
    deps: [:_require-node-ip]
    cmds:
      - talosctl kubeconfig
          --context {{.CLUSTER_NAME}}
```

Key changes from original:
- `deps: [_require-node-ip]` → `deps: [:_require-node-ip]` (leading colon = root task)
- No `version` block vars needed — inherited from root

**Step 2: Verify syntax**

Run: `cd /Users/mark/Developer/HomeLab/lenovo && task --list-all 2>&1 | head -5`

This won't show setup tasks yet (includes not wired), but confirms the root file still parses.

**Step 3: Commit**

```bash
git add taskfiles/setup.yaml
git commit -m "Add taskfiles/setup.yaml with cluster provisioning tasks"
```

---

### Task 2: Create `taskfiles/components.yaml`

**Files:**
- Create: `taskfiles/components.yaml`

**Step 1: Create the file**

```yaml
version: "3"

tasks:

  cilium:
    desc: Install or upgrade Cilium CNI
    deps: [:_require-helm]
    cmds:
      - helm repo add cilium https://helm.cilium.io/ --force-update
      - helm dependency build cluster/apps/cilium
      - helm upgrade --install cilium cluster/apps/cilium
          --namespace kube-system
          --force-conflicts
          --wait --timeout 5m

  traefik:
    desc: Install or upgrade Traefik
    deps: [:_require-helm]
    cmds:
      - helm repo add traefik https://traefik.github.io/charts --force-update
      - helm dependency build cluster/apps/traefik
      - helm upgrade --install traefik cluster/apps/traefik
          --namespace traefik
          --create-namespace
          --force-conflicts
          --wait --timeout 5m

  cert-manager:
    desc: Install or upgrade cert-manager
    deps: [:_require-helm]
    cmds:
      - kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic cloudflare-api-token
          --namespace cert-manager
          --from-literal=api-token={{.CLOUDFLARE_API_TOKEN}}
          --dry-run=client -o yaml | kubectl apply -f -
      - helm repo add jetstack https://charts.jetstack.io --force-update
      - helm dependency build cluster/apps/cert-manager
      - helm upgrade --install cert-manager cluster/apps/cert-manager
          --namespace cert-manager
          --force-conflicts
          --wait --timeout 5m

  longhorn-secret:
    desc: Create Longhorn namespace and S3 backup secret (Longhorn itself is installed by ArgoCD)
    cmds:
      - kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
      - |
        kubectl create secret generic longhorn-s3-secret \
          --namespace longhorn-system \
          --from-literal=AWS_ACCESS_KEY_ID={{.LONGHORN_S3_ACCESS_KEY}} \
          --from-literal=AWS_SECRET_ACCESS_KEY={{.LONGHORN_S3_SECRET_KEY}} \
          --from-literal=AWS_ENDPOINTS={{.LONGHORN_S3_ENDPOINT}} \
          --dry-run=client -o yaml | kubectl apply -f -

  longhorn:
    desc: Install or upgrade Longhorn manually (normally managed by ArgoCD)
    deps: [:_require-helm, longhorn-secret]
    cmds:
      - helm repo add longhorn https://charts.longhorn.io --force-update
      - helm dependency build cluster/apps/longhorn
      - helm upgrade --install longhorn cluster/apps/longhorn
          --namespace longhorn-system
          --force-conflicts
          --wait --timeout 10m

  argocd:
    desc: Install or upgrade ArgoCD
    deps: [:_require-helm]
    cmds:
      - kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
      - |
        if [ ! -f argocd-repo-key ]; then
          echo "ERROR: argocd-repo-key file not found."
          echo "Generate it with:"
          echo "  ssh-keygen -t ed25519 -f argocd-repo-key -N \"\""
          echo "Then add argocd-repo-key.pub as a deploy key in the GitHub repo settings."
          exit 1
        fi
      - |
        kubectl create secret generic argocd-repo-key \
          --namespace argocd \
          --from-literal=type=git \
          --from-literal=url=git@github.com:xmple/talos-cluster.git \
          --from-file=sshPrivateKey=argocd-repo-key \
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl label secret argocd-repo-key -n argocd argocd.argoproj.io/secret-type=repository --overwrite
      - helm repo add argo https://argoproj.github.io/argo-helm --force-update
      - helm dependency build cluster/apps/argocd
      - helm upgrade --install argocd cluster/apps/argocd
          --namespace argocd
          --force-conflicts
          --wait --timeout 5m
```

Key changes:
- `deps: [_require-helm]` → `deps: [:_require-helm]`
- `longhorn` dep `longhorn-secret` stays unprefixed (same file)

**Step 2: Commit**

```bash
git add taskfiles/components.yaml
git commit -m "Add taskfiles/components.yaml with Helm component install tasks"
```

---

### Task 3: Create `taskfiles/day2.yaml`

**Files:**
- Create: `taskfiles/day2.yaml`

**Step 1: Create the file**

```yaml
version: "3"

tasks:

  upgrade-talos:
    desc: Upgrade Talos OS on the node
    deps: [:_require-node-ip]
    vars:
      SCHEMATIC_ID:
        sh: curl -sX POST --data-binary @factory.yaml https://factory.talos.dev/schematics | jq -r '.id'
    cmds:
      - talosctl upgrade
          --context {{.CLUSTER_NAME}}
          --image "factory.talos.dev/installer-secureboot/{{.SCHEMATIC_ID}}:{{.TALOS_VERSION}}"

  upgrade-k8s:
    desc: Upgrade Kubernetes version
    deps: [:_require-node-ip]
    cmds:
      - talosctl upgrade-k8s
          --context {{.CLUSTER_NAME}}
          --to {{.KUBERNETES_VERSION}}

  reboot:
    desc: Reboot the node
    deps: [:_require-node-ip]
    cmds:
      - talosctl reboot
          --context {{.CLUSTER_NAME}}

  reset:
    desc: Wipe the node and start over (DESTRUCTIVE)
    prompt: This will WIPE the node and destroy all data. Are you sure?
    deps: [:_require-node-ip]
    cmds:
      - talosctl reset
          --context {{.CLUSTER_NAME}}
          --graceful=false
          --reboot
```

Note: `reconfigure` is NOT here — it lives in root `Taskfile.yaml` as a top-level wrapper.

**Step 2: Commit**

```bash
git add taskfiles/day2.yaml
git commit -m "Add taskfiles/day2.yaml with upgrade, reboot, and reset tasks"
```

---

### Task 4: Create `taskfiles/utility.yaml`

**Files:**
- Create: `taskfiles/utility.yaml`

**Step 1: Create the file**

```yaml
version: "3"

tasks:

  status:
    desc: Show node health and cluster status
    deps: [:_require-node-ip]
    preconditions:
      - sh: command -v cilium
        msg: "cilium CLI is required. Install with: brew install cilium-cli"
    cmds:
      - talosctl health
          --context {{.CLUSTER_NAME}}
      - kubectl --context admin@{{.CLUSTER_NAME}} get nodes -o wide
      - cilium status --context admin@{{.CLUSTER_NAME}}

  dashboard:
    desc: Open Talos dashboard
    deps: [:_require-node-ip]
    interactive: true
    cmds:
      - talosctl dashboard
          --context {{.CLUSTER_NAME}}

  disks:
    desc: List disks on the node (useful before first install)
    deps: [:_require-node-ip]
    cmds:
      - talosctl get disks
          --insecure --nodes {{.NODE_IP}}

  links:
    desc: List network interfaces on the node
    deps: [:_require-node-ip]
    cmds:
      - talosctl get links
          --insecure --nodes {{.NODE_IP}}
```

**Step 2: Commit**

```bash
git add taskfiles/utility.yaml
git commit -m "Add taskfiles/utility.yaml with status, dashboard, and diagnostic tasks"
```

---

### Task 5: Rewrite root `Taskfile.yaml`

**Files:**
- Modify: `Taskfile.yaml`

**Step 1: Replace `Taskfile.yaml` with the thin entry point**

```yaml
version: "3"

includes:
  setup:
    taskfile: ./taskfiles/setup.yaml
  components:
    taskfile: ./taskfiles/components.yaml
  day2:
    taskfile: ./taskfiles/day2.yaml
  utility:
    taskfile: ./taskfiles/utility.yaml

vars:
  CLUSTER_NAME:
    sh: yq '.cluster_name' vars.yaml
  NODE_IP:
    sh: yq '.node_ip // ""' vars.yaml
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
  CILIUM_VERSION:
    sh: yq '.cilium_version' vars.yaml
  TRAEFIK_VERSION:
    sh: yq '.traefik_version' vars.yaml
  CERT_MANAGER_VERSION:
    sh: yq '.cert_manager_version' vars.yaml
  CLOUDFLARE_API_TOKEN:
    sh: yq '.cloudflare_api_token' vars.yaml
  ARGOCD_VERSION:
    sh: yq '.argocd_version' vars.yaml
  LONGHORN_VERSION:
    sh: yq '.longhorn_version' vars.yaml
  LONGHORN_S3_ENDPOINT:
    sh: yq '.longhorn_s3_endpoint' vars.yaml
  LONGHORN_S3_ACCESS_KEY:
    sh: yq '.longhorn_s3_access_key' vars.yaml
  LONGHORN_S3_SECRET_KEY:
    sh: yq '.longhorn_s3_secret_key' vars.yaml

tasks:

  _require-node-ip:
    internal: true
    silent: true
    preconditions:
      - sh: '[ -n "{{.NODE_IP}}" ]'
        msg: "NODE_IP is required. Set it in vars.yaml or run: task set-node NODE_IP=x.x.x.x"

  _require-helm:
    internal: true
    silent: true
    preconditions:
      - sh: command -v helm
        msg: "helm is required. Install with: brew install helm"

  set-node:
    desc: Save the node IP for subsequent commands
    cmds:
      - yq -i '.node_ip = "{{.NODE_IP}}"' vars.yaml
      - echo "Node IP set to {{.NODE_IP}}"
    preconditions:
      - sh: '[ -n "{{.NODE_IP}}" ]'
        msg: "Usage: task set-node NODE_IP=x.x.x.x"

  setup:
    desc: "Full initial setup: generate, patch, apply, bootstrap, kubeconfig"
    interactive: true
    cmds:
      - task: set-node
        vars: { NODE_IP: "{{.NODE_IP}}" }
      - task: setup:generate
      - task: setup:patch
      - task: setup:apply
      - echo "Remove the bootable ISO/USB and press Enter to continue..."
      - read -r
      - |
        echo "Waiting for Talos API to become reachable..."
        until talosctl --context {{.CLUSTER_NAME}} version >/dev/null 2>&1; do
          sleep 5
        done
        echo "Talos API is up."
      - task: setup:bootstrap
      - task: setup:kubeconfig
      - task: components:cilium
      - task: components:traefik
      - task: components:cert-manager
      - task: components:longhorn-secret
      - task: components:argocd
      - echo "Waiting for cluster to become healthy..."
      - talosctl health
          --context {{.CLUSTER_NAME}}
          --wait-timeout 5m
      - echo "Cluster is ready! Use 'kubectl --context admin@{{.CLUSTER_NAME}} get nodes' to verify."

  reconfigure:
    desc: Re-patch and apply config changes (edit patches first, then run this)
    deps: [_require-node-ip]
    cmds:
      - task: setup:patch
      - talosctl apply-config
          --context {{.CLUSTER_NAME}}
          --file generated/controlplane.yaml
```

Key changes:
- `includes:` block added at top
- `setup` task calls now use `setup:generate`, `setup:patch`, `components:cilium`, etc.
- `reconfigure` calls `setup:patch` instead of `patch`
- All domain tasks removed (moved to their respective files)

**Step 2: Verify all tasks resolve**

Run: `task --list-all`

Expected output should show all tasks with their namespaced names:
- `setup`, `reconfigure`, `set-node` (root)
- `setup:download`, `setup:apply`, `setup:kubeconfig` (setup namespace)
- `components:cilium`, `components:traefik`, etc. (components namespace)
- `day2:upgrade-talos`, `day2:upgrade-k8s`, etc. (day2 namespace)
- `utility:status`, `utility:dashboard`, etc. (utility namespace)

**Step 3: Commit**

```bash
git add Taskfile.yaml
git commit -m "Rewrite root Taskfile.yaml as thin entry point with namespaced includes"
```

---

### Task 6: Update CLAUDE.md command references

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the Commands section**

Replace the component install commands to use namespaced names:

```markdown
### Individual Component Install/Upgrade
```bash
task components:cilium          # Install/upgrade Cilium CNI (kube-system)
task components:traefik         # Install/upgrade Traefik (traefik namespace)
task components:cert-manager    # Install/upgrade cert-manager (cert-manager namespace)
task components:longhorn        # Install/upgrade Longhorn (longhorn-system namespace)
task components:argocd          # Install/upgrade ArgoCD (argocd namespace)
```

### Day-2 Operations
```bash
task day2:upgrade-talos   # Upgrade Talos OS
task day2:upgrade-k8s     # Upgrade Kubernetes
task reconfigure          # Re-apply Talos config patches (top-level wrapper)
task utility:status       # Cluster health check
task utility:dashboard    # Interactive Talos dashboard
```
```

Also update any other references throughout the file (e.g., `task cert-manager` → `task components:cert-manager`, `task longhorn-secret` → `task components:longhorn-secret`).

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md command references for namespaced Taskfile structure"
```

---

### Task 7: Verify end-to-end

**Step 1: List all tasks**

Run: `task --list`

Confirm all public tasks appear with correct namespacing.

**Step 2: Dry-run a non-destructive task**

Run: `task --dry setup:download`

Confirm it resolves the task and shows the commands it would run (including the inherited `TALOS_VERSION` var from root).

**Step 3: Dry-run a cross-namespace task**

Run: `task --dry reconfigure`

Confirm it resolves `setup:patch` and shows the full command chain.

**Step 4: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "Fix any issues found during verification"
```
