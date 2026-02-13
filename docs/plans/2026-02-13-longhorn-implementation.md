# Longhorn Storage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Longhorn v1.11.0 as the cluster's persistent storage provider with daily S3 backups to TrueNAS/Minio.

**Architecture:** Wrapper Helm chart at `cluster/apps/longhorn/` following the existing pattern (Chart.yaml dependency + values.yaml + config.json + templates/). Talos kubelet extra mount patch enables host storage access. S3 backup credentials created by Taskfile, backup schedule declared as a RecurringJob CRD.

**Tech Stack:** Longhorn 1.11.0, Talos Linux, Helm, ArgoCD (auto-discovery via config.json), Gateway API (HTTPRoute)

---

### Task 1: Create the Talos machine config patch

**Files:**
- Create: `patches/longhorn.yaml`

**Context:** Longhorn needs the kubelet to bind-mount `/var/lib/longhorn` from the host filesystem. Without this, Longhorn pods cannot access the host's storage directory. Existing patches (`patches/cni.yaml`, `patches/controlplane.yaml`) follow the same Talos machine config format.

**Step 1: Create the patch file**

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
```

**Step 2: Commit**

```bash
git add patches/longhorn.yaml
git commit -m "Add Talos kubelet extra mount patch for Longhorn"
```

---

### Task 2: Add the Longhorn patch to Taskfile's patch task

**Files:**
- Modify: `Taskfile.yaml:117-123` (the `patch` task's `talosctl machineconfig patch` command)

**Context:** The `patch` task in `Taskfile.yaml` chains multiple `--patch` flags to apply all machine config patches. The new `patches/longhorn.yaml` must be added to this list so it's included in both `task setup` and `task reconfigure`.

**Step 1: Add the Longhorn patch flag**

Find the `talosctl machineconfig patch` command at line 117 and add `--patch @patches/longhorn.yaml` to the list. The updated command should be:

```yaml
      - talosctl machineconfig patch generated/controlplane.yaml
          --patch @patches/controlplane.yaml
          --patch @patches/cni.yaml
          --patch @patches/longhorn.yaml
          --patch @generated/common-patch.yaml
          --patch @generated/install-image-patch.yaml
          --patch @generated/tailscale-patch.yaml
          --output generated/controlplane.yaml
```

Place it after the static patches (controlplane, cni) and before the generated patches (common, install-image, tailscale) for logical grouping.

**Step 2: Commit**

```bash
git add Taskfile.yaml
git commit -m "Add Longhorn kubelet mount patch to Talos config generation"
```

---

### Task 3: Create the wrapper Helm chart

**Files:**
- Create: `cluster/apps/longhorn/Chart.yaml`
- Create: `cluster/apps/longhorn/values.yaml`
- Create: `cluster/apps/longhorn/config.json`

**Context:** Every component follows the wrapper Helm chart pattern. The Chart.yaml declares the upstream chart as a dependency. All values in values.yaml must be nested under `longhorn:` because Helm scopes values to the dependency name. The config.json enables ArgoCD auto-discovery via the ApplicationSet's git files generator.

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: longhorn
version: 0.1.0
dependencies:
  - name: longhorn
    version: "1.11.0"
    repository: https://charts.longhorn.io
```

**Step 2: Create values.yaml**

```yaml
longhorn:
  defaultSettings:
    defaultReplicaCount: 1
    defaultDataPath: /var/lib/longhorn
    backupTarget: "s3://longhorn-backup@us-east-1/"
    backupTargetCredentialSecret: longhorn-s3-secret
  persistence:
    defaultClass: true
    defaultClassReplicaCount: 1
```

**Important:** The `backupTarget` format is `s3://<bucket>@<region>/`. Update the bucket name and region to match the actual Minio configuration. The region for Minio is typically `us-east-1` (the default).

**Step 3: Create config.json**

```json
{"appName": "longhorn", "namespace": "longhorn-system", "chartPath": "cluster/apps/longhorn"}
```

**Step 4: Verify the chart builds**

Run: `helm repo add longhorn https://charts.longhorn.io --force-update && helm dependency build cluster/apps/longhorn`

Expected: Chart.lock created, longhorn-1.11.0.tgz downloaded to `cluster/apps/longhorn/charts/`.

**Step 5: Commit** (exclude the `charts/` directory — it's a build artifact)

Check if `.gitignore` already covers `charts/` directories. If not, the `Chart.lock` should be committed but `charts/*.tgz` should not.

```bash
git add cluster/apps/longhorn/Chart.yaml cluster/apps/longhorn/values.yaml cluster/apps/longhorn/config.json cluster/apps/longhorn/Chart.lock
git commit -m "Add Longhorn wrapper Helm chart with S3 backup config"
```

---

### Task 4: Create the RecurringJob template for daily backups

**Files:**
- Create: `cluster/apps/longhorn/templates/recurring-job.yaml`

**Context:** Longhorn's RecurringJob CRD defines automated backup schedules. The `groups: ["default"]` setting applies the job to all volumes in the default group, which is what Longhorn assigns to new volumes automatically. This template is deployed alongside the Longhorn chart by the wrapper.

**Step 1: Create the RecurringJob manifest**

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups:
    - default
  retain: 7
  concurrency: 1
```

This runs a backup at 2 AM daily and keeps 7 backups (one week of history).

**Step 2: Commit**

```bash
git add cluster/apps/longhorn/templates/recurring-job.yaml
git commit -m "Add daily S3 backup RecurringJob for Longhorn volumes"
```

---

### Task 5: Create the HTTPRoute template for UI access

**Files:**
- Create: `cluster/apps/longhorn/templates/httproute.yaml`

**Context:** The Longhorn UI is exposed via the existing Traefik Gateway, same pattern as ArgoCD's HTTPRoute at `cluster/apps/argocd/templates/httproute.yaml`. All API server defaults (group, kind, weight, path type) must be explicit to prevent ArgoCD drift — this is a documented gotcha in CLAUDE.md. The existing ArgoCD HTTPRoute does NOT use `sectionName`, so we match that convention.

**Step 1: Create the HTTPRoute manifest**

Reference pattern from `cluster/apps/argocd/templates/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-ui
  namespace: longhorn-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: traefik
  hostnames:
    - longhorn.xmple.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: longhorn-frontend
          port: 80
          weight: 1
```

**Important:** The service name is `longhorn-frontend` — this is the Longhorn UI service created by the Helm chart. Verify this after first install with `kubectl get svc -n longhorn-system`.

**Step 2: Commit**

```bash
git add cluster/apps/longhorn/templates/httproute.yaml
git commit -m "Add HTTPRoute for Longhorn UI at longhorn.xmple.io"
```

---

### Task 6: Add Longhorn variables to vars.yaml and vars.yaml.example

**Files:**
- Modify: `vars.yaml` (git-ignored, local only)
- Modify: `vars.yaml.example`

**Context:** `vars.yaml` holds all cluster config including secrets and is git-ignored. `vars.yaml.example` is the committed template with placeholder values. The Taskfile reads these values using `yq`.

**Step 1: Add entries to vars.yaml**

Append these entries (replace placeholders with actual Minio credentials):

```yaml
longhorn_version: "1.11.0"
longhorn_s3_endpoint: "https://truenas.local:9000"
longhorn_s3_bucket: "longhorn-backup"
longhorn_s3_region: "us-east-1"
longhorn_s3_access_key: "<your-actual-access-key>"
longhorn_s3_secret_key: "<your-actual-secret-key>"
```

**Step 2: Add entries to vars.yaml.example**

Append these entries with placeholder values:

```yaml
longhorn_version: "1.11.0"
longhorn_s3_endpoint: "https://truenas.local:9000"
longhorn_s3_bucket: "longhorn-backup"
longhorn_s3_region: "us-east-1"
longhorn_s3_access_key: "your-minio-access-key"
longhorn_s3_secret_key: "your-minio-secret-key"
```

**Step 3: Commit** (only vars.yaml.example — vars.yaml is git-ignored)

```bash
git add vars.yaml.example
git commit -m "Add Longhorn S3 backup variables to vars.yaml.example"
```

---

### Task 7: Add the Longhorn task to Taskfile

**Files:**
- Modify: `Taskfile.yaml`

**Context:** Each component has a standalone Taskfile task for bootstrap and day-2 installs. The Longhorn task follows the cert-manager pattern: create namespace, create secret, helm install. It uses a 10-minute timeout (vs 5m for others) because Longhorn deploys many components.

**Step 1: Add Longhorn variables to the vars section**

After the existing `ARGOCD_VERSION` variable (around line 27), add:

```yaml
  LONGHORN_VERSION:
    sh: yq '.longhorn_version' vars.yaml
  LONGHORN_S3_ENDPOINT:
    sh: yq '.longhorn_s3_endpoint' vars.yaml
  LONGHORN_S3_BUCKET:
    sh: yq '.longhorn_s3_bucket' vars.yaml
  LONGHORN_S3_REGION:
    sh: yq '.longhorn_s3_region' vars.yaml
  LONGHORN_S3_ACCESS_KEY:
    sh: yq '.longhorn_s3_access_key' vars.yaml
  LONGHORN_S3_SECRET_KEY:
    sh: yq '.longhorn_s3_secret_key' vars.yaml
```

**Step 2: Add the Longhorn task**

Place it after the `cert-manager` task and before the `argocd` task (around line 214), matching the bootstrap order:

```yaml
  longhorn:
    desc: Install or upgrade Longhorn
    deps: [_require-helm]
    cmds:
      - kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
      - |
        kubectl create secret generic longhorn-s3-secret \
          --namespace longhorn-system \
          --from-literal=AWS_ACCESS_KEY_ID={{.LONGHORN_S3_ACCESS_KEY}} \
          --from-literal=AWS_SECRET_ACCESS_KEY={{.LONGHORN_S3_SECRET_KEY}} \
          --from-literal=AWS_ENDPOINTS={{.LONGHORN_S3_ENDPOINT}} \
          --dry-run=client -o yaml | kubectl apply -f -
      - helm repo add longhorn https://charts.longhorn.io --force-update
      - helm dependency build cluster/apps/longhorn
      - helm upgrade --install longhorn cluster/apps/longhorn
          --namespace longhorn-system
          --force-conflicts
          --wait --timeout 10m
```

**Step 3: Add Longhorn to the setup task's bootstrap chain**

In the `setup` task (around line 147), add `- task: longhorn` between `cert-manager` and `argocd`:

```yaml
      - task: cert-manager
      - task: longhorn
      - task: argocd
```

**Step 4: Commit**

```bash
git add Taskfile.yaml
git commit -m "Add Longhorn install task and add to bootstrap chain"
```

---

### Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Context:** CLAUDE.md documents all components, commands, secrets, and gotchas for the cluster. It needs updating to reflect Longhorn as a new component.

**Step 1: Update the Stack line**

Change line 9 from:
```
**Stack:** Talos v1.12.3, Kubernetes v1.35.0, Cilium CNI, Traefik (Gateway API), cert-manager, ArgoCD
```
to:
```
**Stack:** Talos v1.12.3, Kubernetes v1.35.0, Cilium CNI, Traefik (Gateway API), cert-manager, Longhorn, ArgoCD
```

**Step 2: Add Longhorn to the Individual Component Install/Upgrade section**

After the `task argocd` line, add:
```bash
task longhorn        # Install/upgrade Longhorn (longhorn-system namespace)
```

**Step 3: Add Longhorn to the secrets table**

Add a row:
```
| `longhorn-s3-secret` | longhorn-system | `task longhorn` (from vars.yaml) |
```

**Step 4: Add Longhorn-specific gotchas to the Critical Gotchas section**

Add these entries:
```
**Longhorn on Talos requires kubelet extra mount** for `/var/lib/longhorn` — the patch in `patches/longhorn.yaml` must be applied and the node rebooted before Longhorn install.

**After reinstalling Longhorn**, existing PVCs may need manual reattachment if the volume data still exists on disk.
```

**Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "Document Longhorn in CLAUDE.md (commands, secrets, gotchas)"
```

---

### Task 9: Verify helm template renders correctly

**Files:** None (validation only)

**Context:** Before deploying, verify that `helm template` produces valid manifests. This is the same rendering ArgoCD uses to compute desired state, so any issues here will cause ArgoCD sync failures.

**Step 1: Run helm template**

```bash
helm template longhorn cluster/apps/longhorn --namespace longhorn-system
```

Expected: Valid YAML output including Longhorn Deployments, DaemonSets, Services, the RecurringJob CRD, and the HTTPRoute. No template errors.

**Step 2: Verify key resources in the output**

Check for these resources in the rendered output:
- `RecurringJob/daily-backup` with cron `0 2 * * *`
- `HTTPRoute/longhorn-ui` with hostname `longhorn.xmple.io`
- `StorageClass/longhorn` with `storageclass.kubernetes.io/is-default-class: "true"`
- Longhorn settings with `defaultReplicaCount: 1`

**Step 3: No commit needed** — this is a validation step.

---

### Task 10: Deploy to the cluster

**Context:** This task requires the live cluster. First apply the Talos patch (needs reboot), then install Longhorn via the Taskfile task.

**Step 1: Apply the Talos patch and reboot**

```bash
task reconfigure
```

This runs `talosctl machineconfig patch` with all patches including the new `patches/longhorn.yaml`, then applies the config. Verify the node reboots and comes back up:

```bash
talosctl health --context lenovo --wait-timeout 5m
```

**Step 2: Install Longhorn**

```bash
task longhorn
```

Expected: Helm installs Longhorn with all components. The `--wait` flag ensures all pods are ready before the task completes.

**Step 3: Verify Longhorn is running**

```bash
kubectl get pods -n longhorn-system
kubectl get storageclass
kubectl get recurringjobs -n longhorn-system
kubectl get httproutes -n longhorn-system
```

Expected:
- All Longhorn pods in Running state
- `longhorn` StorageClass marked as `(default)`
- `daily-backup` RecurringJob exists
- `longhorn-ui` HTTPRoute exists

**Step 4: Verify S3 backup target**

Open `https://longhorn.xmple.io` in a browser. Navigate to Settings > Backup Target. Verify:
- Backup Target: `s3://longhorn-backup@us-east-1/`
- Backup Target Credential Secret: `longhorn-s3-secret`

**Step 5: Test a backup manually**

Create a test PVC and trigger a manual backup through the Longhorn UI to confirm S3 connectivity works end-to-end.

**Step 6: Push to git for ArgoCD adoption**

```bash
git push origin main
```

ArgoCD will discover the new `longhorn` app via config.json and adopt it. Verify in ArgoCD UI that the `longhorn` app appears and shows as Synced/Healthy.

---

### Task 11: Final commit and push

**Context:** Ensure all changes are committed and pushed so ArgoCD can manage Longhorn going forward.

**Step 1: Verify clean git state**

```bash
git status
```

Expected: No uncommitted changes (all tasks above should have committed their work).

**Step 2: Push all commits**

```bash
git push origin main
```

**Step 3: Verify ArgoCD shows Longhorn as Synced**

Check the ArgoCD UI at `https://argocd-beta.xmple.io` — the `longhorn` app should appear in the app list and show as Synced + Healthy.
