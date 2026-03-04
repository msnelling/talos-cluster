# Gitea Runner Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy the Gitea Act Runner via a wrapper Helm chart so Gitea Actions workflows can execute locally.

**Architecture:** Wrapper Helm chart (`gitea-charts/actions` v0.0.3) in a dedicated `gitea-runner` namespace with Docker-in-Docker execution. Runner registers with Gitea via internal service URL.

**Tech Stack:** Helm, ArgoCD (app-of-apps), Gitea Actions, Docker-in-Docker

---

### Task 1: Create the wrapper Helm chart

**Files:**
- Create: `cluster/apps/gitea-runner/Chart.yaml`
- Create: `cluster/apps/gitea-runner/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: gitea-runner
version: 0.1.0
dependencies:
  - name: actions
    version: "0.0.3"
    repository: https://dl.gitea.com/charts/
```

**Step 2: Create values.yaml**

Values are nested under `actions:` (the dependency name).

```yaml
actions:
  enabled: true
  giteaRootURL: "http://gitea-http.gitea.svc.cluster.local:3000"
  existingSecret: "runner-token"
  existingSecretKey: "token"

  statefulset:
    replicas: 1
    actRunner:
      config: |
        log:
          level: info
        cache:
          enabled: false
        container:
          require_docker: true
          docker_timeout: 300s
```

**Step 3: Build and lint the chart**

Run: `helm repo add gitea-charts https://dl.gitea.com/charts/ --force-update && helm dependency build cluster/apps/gitea-runner && helm lint cluster/apps/gitea-runner`
Expected: "1 chart(s) linted, 0 chart(s) failed"

**Step 4: Verify rendered output**

Run: `helm template test cluster/apps/gitea-runner -n gitea-runner | head -80`
Expected: ConfigMap with act-runner config and StatefulSet with DinD sidecar

**Step 5: Commit**

```bash
git add cluster/apps/gitea-runner/
git commit -m "feat(gitea-runner): add wrapper Helm chart for Gitea Act Runner"
```

---

### Task 2: Create namespace template with privileged PodSecurity

**Files:**
- Create: `cluster/apps/gitea-runner/templates/namespace.yaml`

**Step 1: Create the namespace template**

Follow the same pattern as `cluster/apps/longhorn/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gitea-runner
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

**Step 2: Verify the namespace renders in template output**

Run: `helm template test cluster/apps/gitea-runner -n gitea-runner | grep -A 8 'kind: Namespace'`
Expected: Namespace resource with all three privileged PodSecurity labels

**Step 3: Run full validation**

Run: `helm template test cluster/apps/gitea-runner -n gitea-runner | kubeconform -strict -ignore-missing-schemas -summary`
Expected: All resources pass validation

**Step 4: Commit**

```bash
git add cluster/apps/gitea-runner/templates/namespace.yaml
git commit -m "feat(gitea-runner): add privileged namespace template for DinD"
```

---

### Task 3: Add gitea-runner to the services ArgoCD group

**Files:**
- Modify: `cluster/groups/services/values.yaml`

**Step 1: Add the gitea-runner entry**

Add to the `apps:` list in `cluster/groups/services/values.yaml`:

```yaml
apps:
  - name: gitea
    namespace: gitea
    path: cluster/apps/gitea
  - name: gitea-runner
    namespace: gitea-runner
    path: cluster/apps/gitea-runner
```

**Step 2: Verify the Application CR renders correctly**

Run: `helm template app-services cluster/groups/services | grep -A 20 'name: gitea-runner'`
Expected: Application CR with correct namespace (`gitea-runner`), path (`cluster/apps/gitea-runner`), and sync policy

**Step 3: Commit**

```bash
git add cluster/groups/services/values.yaml
git commit -m "feat(gitea-runner): add to services ArgoCD group"
```

---

### Task 4: Add runner-token secret task to Taskfile

**Files:**
- Modify: `taskfiles/components.yaml`
- Modify: `vars.yaml.example`

**Step 1: Add the runner-token task**

Add to `taskfiles/components.yaml` after the `gitea-secrets` task:

```yaml
  runner-token:
    desc: Create Gitea runner registration token secret (namespace created by ArgoCD)
    cmds:
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: runner-token
          namespace: gitea-runner
        type: Opaque
        stringData:
          token: "{{.GITEA_RUNNER_TOKEN}}"
        EOF
```

**Step 2: Add GITEA_RUNNER_TOKEN to vars.yaml.example**

Add under the `# Gitea` section:

```yaml
# Gitea Runner
gitea_runner_token: ""  # Get from Gitea admin UI: /-/admin/actions/runners
```

**Step 3: Verify Taskfile parses correctly**

Run: `cd /Users/mark/Developer/HomeLab/lenovo && task --list | grep runner`
Expected: `* components:runner-token:     Create Gitea runner registration token secret (namespace created by ArgoCD)`

**Step 4: Commit**

```bash
git add taskfiles/components.yaml vars.yaml.example
git commit -m "feat(gitea-runner): add runner-token secret task and vars example"
```

---

### Task 5: Final validation

**Step 1: Full chart validation**

Run: `helm dependency build cluster/apps/gitea-runner && helm lint cluster/apps/gitea-runner && helm template test cluster/apps/gitea-runner -n gitea-runner | kubeconform -strict -ignore-missing-schemas -summary`
Expected: Lint passes, all resources valid

**Step 2: Verify group renders both apps**

Run: `helm template app-services cluster/groups/services | grep 'name: gitea' | head -5`
Expected: Both `gitea` and `gitea-runner` Application CRs

**Step 3: Verify no regressions in existing gitea chart**

Run: `helm dependency build cluster/apps/gitea && helm lint cluster/apps/gitea`
Expected: Passes without errors
