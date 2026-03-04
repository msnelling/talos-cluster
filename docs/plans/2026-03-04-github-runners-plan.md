# GitHub Actions Runners (ARC) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Install GitHub Actions Runner Controller (ARC) to provide self-hosted runners for the `sociaei` GitHub organization.

**Architecture:** Two wrapper Helm charts — `arc-controller` (operator, installed once) and `arc-runner` (runner scale set, registers with GitHub). Both managed by ArgoCD in the services group. GitHub App authentication via a pre-defined Kubernetes secret.

**Tech Stack:** ARC v0.13.1 (OCI charts from GHCR), Kubernetes container mode, ArgoCD GitOps

---

### Task 1: Create the arc-controller wrapper chart

**Files:**
- Create: `cluster/apps/arc-controller/Chart.yaml`
- Create: `cluster/apps/arc-controller/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: arc-controller
version: 0.1.0
dependencies:
  - name: gha-runner-scale-set-controller
    version: "0.13.1"
    repository: oci://ghcr.io/actions/actions-runner-controller-charts
```

**Step 2: Create values.yaml**

Values are nested under the dependency name `gha-runner-scale-set-controller:`.

```yaml
gha-runner-scale-set-controller:
  flags:
    logLevel: "info"
```

Only override: log level from `debug` to `info` (less noisy for homelab).

**Step 3: Build and lint the chart**

Run: `helm dependency build cluster/apps/arc-controller && helm lint cluster/apps/arc-controller`
Expected: Lint passes with no errors.

**Step 4: Template and validate**

Run: `helm template test cluster/apps/arc-controller | kubeconform -strict -ignore-missing-schemas -summary`
Expected: Summary shows 0 invalid resources.

**Step 5: Commit**

```bash
git add cluster/apps/arc-controller/
git commit -m "feat(arc-controller): add ARC operator wrapper chart"
```

---

### Task 2: Create the arc-runner wrapper chart

**Files:**
- Create: `cluster/apps/arc-runner/Chart.yaml`
- Create: `cluster/apps/arc-runner/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: arc-runner
version: 0.1.0
dependencies:
  - name: gha-runner-scale-set
    version: "0.13.1"
    repository: oci://ghcr.io/actions/actions-runner-controller-charts
```

**Step 2: Create values.yaml**

Values nested under `gha-runner-scale-set:`. Use a pre-defined secret (`arc-github-app`) created by the Taskfile secret task. The `controllerServiceAccount` must point to the controller's service account in its namespace so the runner scale set can create the required RoleBinding.

```yaml
gha-runner-scale-set:
  githubConfigUrl: "https://github.com/sociaei"
  githubConfigSecret: arc-github-app

  runnerScaleSetName: "arc-runner"

  minRunners: 1
  maxRunners: 5

  containerMode:
    type: "kubernetes"
    kubernetesModeWorkVolumeClaim:
      accessModes: ["ReadWriteOnce"]
      storageClassName: "longhorn-single-replica"
      resources:
        requests:
          storage: 1Gi

  controllerServiceAccount:
    namespace: arc-controller
    name: arc-controller-gha-rs-controller
```

**Step 3: Build and lint the chart**

Run: `helm dependency build cluster/apps/arc-runner && helm lint cluster/apps/arc-runner`
Expected: Lint passes with no errors.

**Step 4: Template and validate**

Run: `helm template test cluster/apps/arc-runner | kubeconform -strict -ignore-missing-schemas -summary`
Expected: Summary shows 0 invalid resources (CRDs may show as missing schemas — that's fine with `-ignore-missing-schemas`).

**Step 5: Commit**

```bash
git add cluster/apps/arc-runner/
git commit -m "feat(arc-runner): add runner scale set wrapper chart for sociaei org"
```

---

### Task 3: Add both apps to the services group

**Files:**
- Modify: `cluster/groups/services/values.yaml`

**Step 1: Add arc-controller and arc-runner entries**

Add to the `apps` list in `cluster/groups/services/values.yaml`. The controller must be listed before the runner (ArgoCD syncs in order, and the runner needs the controller's CRDs):

```yaml
  - name: arc-controller
    namespace: arc-controller
    path: cluster/apps/arc-controller
  - name: arc-runner
    namespace: arc-runner
    path: cluster/apps/arc-runner
```

**Step 2: Lint the group chart**

Run: `helm lint cluster/groups/services`
Expected: Lint passes.

**Step 3: Template and verify Application CRs render**

Run: `helm template test cluster/groups/services`
Expected: Output includes Application CRs for `arc-controller` and `arc-runner` with correct namespace/path.

**Step 4: Commit**

```bash
git add cluster/groups/services/values.yaml
git commit -m "feat(services): add arc-controller and arc-runner to services group"
```

---

### Task 4: Add secret task and vars.yaml entries

**Files:**
- Modify: `taskfiles/components.yaml` — add `github-runner-secret` task
- Modify: `Taskfile.yaml` — add variable definitions
- Modify: `vars.yaml.example` — add example entries

**Step 1: Add vars to Taskfile.yaml**

Add after the `# Renovate` section (around line 82):

```yaml
  # GitHub Actions Runner (ARC)
  GITHUB_APP_ID:
    sh: yq '.github_app_id' vars.yaml
  GITHUB_APP_INSTALLATION_ID:
    sh: yq '.github_app_installation_id' vars.yaml
```

**Step 2: Add secret task to taskfiles/components.yaml**

Add after the `runner-token` task (after line 225). Uses `--from-file` for the private key (like `renovate-secret` pattern) and heredoc for the other fields:

```yaml
  github-runner-secret:
    desc: Create GitHub App secret for ARC runners (namespace created by ArgoCD)
    preconditions:
      - sh: test -f github-app-key.pem
        msg: |
          github-app-key.pem not found. Download it from:
            GitHub → Settings → Developer settings → GitHub Apps → your app → Generate a private key
    cmds:
      - |
        cat <<EOF | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: arc-github-app
          namespace: arc-runner
        type: Opaque
        stringData:
          github_app_id: "{{.GITHUB_APP_ID}}"
          github_app_installation_id: "{{.GITHUB_APP_INSTALLATION_ID}}"
          github_app_private_key: |
        $(sed 's/^/        /' github-app-key.pem)
        EOF
```

**Step 3: Add example entries to vars.yaml.example**

Add after the `# Renovate` section:

```yaml
# GitHub Actions Runner (ARC)
github_app_id: "123456"
github_app_installation_id: "12345678"
```

**Step 4: Commit**

```bash
git add Taskfile.yaml taskfiles/components.yaml vars.yaml.example
git commit -m "feat(arc): add GitHub App secret task and vars"
```

---

### Task 5: Update CLAUDE.md documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add `github-runner-secret` to the Commands section**

In the "Individual Component Install/Upgrade" list, add:

```
task components:github-runner-secret  # Create GitHub App secret for ARC runners (arc-runner namespace)
```

**Step 2: Add secret to the Secrets table**

Add row:

```
| `arc-github-app` | arc-runner | `task components:github-runner-secret` (from vars.yaml + `github-app-key.pem` file) |
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add ARC runner secret to CLAUDE.md"
```

---

### Task 6: Validate full chart rendering end-to-end

**Step 1: Re-build all dependencies**

Run:
```bash
helm dependency build cluster/apps/arc-controller
helm dependency build cluster/apps/arc-runner
```

**Step 2: Template the services group and verify all apps**

Run: `helm template test cluster/groups/services`
Expected: Application CRs for gitea, gitea-runner, arc-controller, and arc-runner.

**Step 3: Lint everything**

Run:
```bash
helm lint cluster/apps/arc-controller
helm lint cluster/apps/arc-runner
helm lint cluster/groups/services
```
Expected: All pass.

**Step 4: Kubeconform validation**

Run:
```bash
helm template test cluster/apps/arc-controller | kubeconform -strict -ignore-missing-schemas -summary
helm template test cluster/apps/arc-runner | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: 0 invalid resources.
