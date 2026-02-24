# Renovate Self-Hosted CronJob Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Renovate as a Kubernetes CronJob that scans this GitHub repo hourly for dependency updates.

**Architecture:** Wrapper Helm chart around the official `renovate/renovate` chart (v46.31.7), deployed to the `renovate` namespace via ArgoCD's platform app group. GitHub PAT injected via Taskfile secret task.

**Tech Stack:** Helm, ArgoCD, Renovate, Taskfile, yq

---

### Task 1: Create the wrapper Helm chart

**Files:**
- Create: `cluster/apps/renovate/Chart.yaml`
- Create: `cluster/apps/renovate/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: renovate
version: 0.1.0
dependencies:
  - name: renovate
    version: "46.31.7"
    repository: https://docs.renovatebot.com/helm-charts
```

**Step 2: Create values.yaml**

```yaml
renovate:
  cronjob:
    schedule: "0 * * * *"
    concurrencyPolicy: Forbid
    jobRestartPolicy: Never
  renovate:
    config: |
      {
        "platform": "github",
        "repositories": ["xmple/talos-cluster"],
        "onboardingConfig": {
          "extends": ["config:recommended"]
        }
      }
  secrets:
    RENOVATE_TOKEN: ""
```

**Step 3: Verify chart builds**

Run: `helm repo add renovate https://docs.renovatebot.com/helm-charts --force-update && helm dependency build cluster/apps/renovate`
Expected: `Saving 1 charts` / `Deleting outdated charts`

**Step 4: Verify template renders**

Run: `helm template renovate cluster/apps/renovate --namespace renovate | head -40`
Expected: CronJob resource with schedule `0 * * * *`

**Step 5: Commit**

```bash
git add cluster/apps/renovate/Chart.yaml cluster/apps/renovate/values.yaml
git commit -m "feat(renovate): add wrapper Helm chart for self-hosted Renovate CronJob"
```

---

### Task 2: Add renovate to the platform app group

**Files:**
- Modify: `cluster/groups/platform/values.yaml:7-17`

**Step 1: Add renovate entry to app list**

Append to the `apps:` list in `cluster/groups/platform/values.yaml`:

```yaml
  - name: renovate
    namespace: renovate
    path: cluster/apps/renovate
```

**Step 2: Verify the group chart renders the new Application CR**

Run: `helm template app-platform cluster/groups/platform --namespace argocd | grep -A 5 "name: renovate"`
Expected: Application CR with `name: renovate`, `namespace: argocd`, destination namespace `renovate`

**Step 3: Commit**

```bash
git add cluster/groups/platform/values.yaml
git commit -m "feat(renovate): add renovate to platform app group"
```

---

### Task 3: Add Taskfile secret injection task

**Files:**
- Modify: `Taskfile.yaml:79` (add RENOVATE_GITHUB_TOKEN var)
- Modify: `taskfiles/components.yaml` (add renovate-secret task)

**Step 1: Add var extraction to Taskfile.yaml**

Add after the `GITHUB_OAUTH_CLIENT_SECRET` var block (around line 83):

```yaml
  # Renovate
  RENOVATE_GITHUB_TOKEN:
    sh: yq '.renovate_github_token' vars.yaml
```

**Step 2: Add renovate-secret task to taskfiles/components.yaml**

Add after the `gitea-secrets` task:

```yaml
  renovate-secret:
    desc: Create Renovate GitHub token secret (namespace created by ArgoCD)
    cmds:
      - kubectl create secret generic renovate-token
          --namespace renovate
          --from-literal=RENOVATE_TOKEN={{.RENOVATE_GITHUB_TOKEN}}
          --dry-run=client -o yaml | kubectl apply -f -
```

**Step 3: Verify task appears in task list**

Run: `task --list | grep renovate`
Expected: `* components:renovate-secret: Create Renovate GitHub token secret...`

**Step 4: Commit**

```bash
git add Taskfile.yaml taskfiles/components.yaml
git commit -m "feat(renovate): add Taskfile secret injection for GitHub token"
```

---

### Task 4: Update values.yaml to use existingSecret instead of inline secret

Since the secret is created by the Taskfile (not by Helm `--set`), update the chart values to reference it.

**Files:**
- Modify: `cluster/apps/renovate/values.yaml`

**Step 1: Update values.yaml to use existingSecret**

Replace the `secrets` block with `existingSecret`:

```yaml
renovate:
  cronjob:
    schedule: "0 * * * *"
    concurrencyPolicy: Forbid
    jobRestartPolicy: Never
  renovate:
    config: |
      {
        "platform": "github",
        "repositories": ["xmple/talos-cluster"],
        "onboardingConfig": {
          "extends": ["config:recommended"]
        }
      }
  existingSecret: renovate-token
```

**Step 2: Verify template references the secret**

Run: `helm template renovate cluster/apps/renovate --namespace renovate | grep -A 3 "secretRef\|envFrom\|renovate-token"`
Expected: References to `renovate-token` secret

**Step 3: Commit**

```bash
git add cluster/apps/renovate/values.yaml
git commit -m "feat(renovate): use existingSecret for GitHub token"
```

---

### Task 5: Update vars.yaml.example and CLAUDE.md

**Files:**
- Modify: `vars.yaml.example:56` (end of file)
- Modify: `CLAUDE.md:200` (secrets table)

**Step 1: Add renovate_github_token to vars.yaml.example**

Append to end of file:

```yaml

# Renovate
renovate_github_token: "ghp_your-github-pat-with-repo-scope"
```

**Step 2: Add renovate secret to CLAUDE.md secrets table**

Add row to the secrets table:

```markdown
| `renovate-token` | renovate | `task components:renovate-secret` (from vars.yaml) |
```

**Step 3: Add `task components:renovate-secret` to the component install commands list in CLAUDE.md**

In the "Individual Component Install/Upgrade" section, add:

```bash
task components:renovate-secret  # Create Renovate namespace + GitHub token secret
```

**Step 4: Commit**

```bash
git add vars.yaml.example CLAUDE.md
git commit -m "docs: add Renovate GitHub token to vars example and secrets table"
```

---

### Task 6: Validate end-to-end (dry run)

**Step 1: Build and template the full chart**

Run: `helm dependency build cluster/apps/renovate && helm template renovate cluster/apps/renovate --namespace renovate`
Expected: Valid CronJob manifest with correct schedule, config, and secret reference

**Step 2: Template the platform group to confirm Application CR**

Run: `helm template app-platform cluster/groups/platform --namespace argocd`
Expected: Four Application CRs (cert-manager, longhorn, smb-csi, renovate)

**Step 3: Verify task list is complete**

Run: `task --list | grep -E "renovate"`
Expected: `components:renovate-secret` task listed

**Step 4: No commit (validation only)**
