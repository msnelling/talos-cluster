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
  secrets:
    RENOVATE_TOKEN: ""
```

The `RENOVATE_TOKEN` is a GitHub PAT with repo scope, injected at install time via `helm --set` (never stored in git).

### Secret Handling

New `renovate_github_token` field in `vars.yaml`. Injected via `task components:renovate` which runs:

```bash
helm upgrade --install renovate cluster/apps/renovate \
  --namespace renovate \
  --set renovate.secrets.RENOVATE_TOKEN={{.RENOVATE_GITHUB_TOKEN}} \
  --force-conflicts \
  --wait --timeout 5m
```

After initial bootstrap, ArgoCD manages the chart. The secret persists in the cluster independently.

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
| `taskfiles/components.yaml` | Edit — add renovate task for secret injection |
| `vars.yaml.example` | Edit — add renovate_github_token field |
| `CLAUDE.md` | Edit — add renovate secret to secrets table |
