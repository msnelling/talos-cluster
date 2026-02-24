# Renovate Self-Hosted CronJob Design

## Goal

Run Renovate as a Kubernetes CronJob to automatically create PRs for dependency updates (Helm chart versions, Docker image tags) in this repository.

## Architecture

Wrapper Helm chart at `cluster/apps/renovate/` wrapping the official `renovate/renovate` chart (v46.31.7). Deployed to the `renovate` namespace via ArgoCD as part of the `platform` app group.

## Components

### Helm Chart (`cluster/apps/renovate/`)

- **Chart.yaml**: Declares `renovate/renovate` as a dependency with pinned version
- **values.yaml**: Self-hosted runner config (platform, repositories, schedule) nested under `renovate:`

No `templates/` directory needed — the upstream chart provides the CronJob, ConfigMap, and Secret.

### Configuration Split

**Self-hosted config (values.yaml inline):** Platform, authentication, repository list, onboarding settings. These configure *where* Renovate runs.

**Repo config (renovate.json in repo root):** Package rules, version filtering, merge strategies. These configure *how* Renovate handles updates. Renovate reads this automatically when scanning the repo.

### values.yaml

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

### Secret Handling (GitHub App)

Authentication uses a GitHub App instead of a PAT. This provides scoped permissions, auto-rotating tokens, and no expiry management.

**Setup:** Create a GitHub App with Contents (read/write), Pull requests (read/write), Issues (read/write), Metadata (read-only) permissions. Install it on the target repo. Download the private key as `renovate-app-key.pem`.

The secret contains `RENOVATE_GITHUB_APP_ID` (from `vars.yaml`) and `RENOVATE_GITHUB_APP_KEY` (from the PEM file). Injected via `task components:renovate-secret`:

```bash
kubectl create secret generic renovate-token \
  --namespace renovate \
  --from-literal=RENOVATE_GITHUB_APP_ID={{.RENOVATE_GITHUB_APP_ID}} \
  --from-file=RENOVATE_GITHUB_APP_KEY=renovate-app-key.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

The secret is created after ArgoCD syncs the chart and creates the namespace.

### ArgoCD Integration

Add to `cluster/groups/platform/values.yaml`:

```yaml
  - name: renovate
    namespace: renovate
    path: cluster/apps/renovate
```

ArgoCD creates the `renovate` namespace via `CreateNamespace=true` and syncs the chart.

## Schedule

Runs every hour (`0 * * * *`). Concurrency policy `Forbid` prevents overlapping runs.

## Files Changed

| File | Action |
|------|--------|
| `cluster/apps/renovate/Chart.yaml` | Create — wrapper chart |
| `cluster/apps/renovate/values.yaml` | Create — CronJob + Renovate config |
| `cluster/groups/platform/values.yaml` | Edit — add renovate to app list |
| `taskfiles/components.yaml` | Edit — add renovate-secret task (GitHub App) |
| `vars.yaml.example` | Edit — add renovate_github_app_id field |
| `.gitignore` | Edit — add renovate-app-key.pem |
| `CLAUDE.md` | Edit — add renovate secret to secrets table |
