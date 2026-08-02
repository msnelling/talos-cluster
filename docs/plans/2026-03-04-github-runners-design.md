# GitHub Actions Runners via ARC

**Date:** 2026-03-04
**Status:** Approved

## Summary

Install GitHub Actions Runner Controller (ARC) to provide self-hosted runners for the `sociaei` GitHub organization. Follows the existing wrapper Helm chart pattern.

## Architecture

Two wrapper Helm charts:

1. **`github-arc-controller`** — Installs the ARC operator (once per cluster). Wraps `gha-runner-scale-set-controller` v0.14.2 from `oci://ghcr.io/actions/actions-runner-controller-charts`.

2. **`github-arc-runner`** — Registers a runner scale set with `https://github.com/sociaei`. Wraps `gha-runner-scale-set` v0.14.2. Kubernetes container mode (ephemeral pods, no DinD). Scaling: 0 min / 3 max.

Both charts use OCI dependencies from GHCR (public, no auth required to pull).

## Group Placement

Both apps go in the **services** group (`cluster/groups/services/`) alongside `gitea` and `gitea-runner`.

## Authentication

GitHub App credentials stored in a `github-arc-app` secret in the `github-arc-runner` namespace. Created via `task components:github-runner-secret`.

### GitHub App Setup

1. Create a GitHub App in your org: **GitHub → Settings → Developer settings → GitHub Apps → New GitHub App**
2. Set the following permissions:
   - **Organization permissions:** Self-hosted runners → Read and write
   - **Repository permissions:** (none required for org-level runners)
3. Install the app on the `sociaei` organization
4. Note the **App ID** and **Installation ID** (visible on the app's settings page after installation)
5. Generate a private key and save as `github-app-key.pem` in the repo root (git-ignored)

### Required inputs
- `github_app_id` — in `vars.yaml`
- `github_app_installation_id` — in `vars.yaml`
- `github-app-key.pem` — local file (git-ignored), GitHub App private key

## Workflow Usage

```yaml
runs-on: github-arc-runner
```

## Components

```
cluster/apps/github-arc-controller/
  Chart.yaml          # depends on gha-runner-scale-set-controller 0.14.2
  values.yaml         # minimal operator config

cluster/apps/github-arc-runner/
  Chart.yaml          # depends on gha-runner-scale-set 0.14.2
  values.yaml         # githubConfigUrl, scaling, kubernetes mode

cluster/groups/services/values.yaml  # add github-arc-controller + github-arc-runner entries
```

## Decisions

- **Kubernetes container mode** over DinD — no Docker build needs, avoids privileged namespace.
- **GitHub App auth** over PAT — better security, higher rate limits, fine-grained permissions.
- **0 min / 3 max scaling** — no idle runner burning homelab resources; accepts a cold start on the first job.
- **Ephemeral work volume on `local-hostpath-ephemeral`** — job scratch is node-local hostpath, not Longhorn: replicating throwaway build data over the network buys nothing. Uses the `Delete` reclaim variant of the hostpath class so each job's PV and directory are reclaimed; the default `local-hostpath` is `Retain` (for CNPG) and would strand both per job. Workflow artifacts still go to GitHub.
