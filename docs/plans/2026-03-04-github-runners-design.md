# GitHub Actions Runners via ARC

**Date:** 2026-03-04
**Status:** Approved

## Summary

Install GitHub Actions Runner Controller (ARC) to provide self-hosted runners for the `sociaei` GitHub organization. Follows the existing wrapper Helm chart pattern.

## Architecture

Two wrapper Helm charts:

1. **`arc-controller`** — Installs the ARC operator (once per cluster). Wraps `gha-runner-scale-set-controller` v0.13.1 from `oci://ghcr.io/actions/actions-runner-controller-charts`.

2. **`arc-runner`** — Registers a runner scale set with `https://github.com/sociaei`. Wraps `gha-runner-scale-set` v0.13.1. Kubernetes container mode (ephemeral pods, no DinD). Scaling: 1 min / 5 max.

Both charts use OCI dependencies from GHCR (public, no auth required to pull).

## Group Placement

Both apps go in the **services** group (`cluster/groups/services/`) alongside `gitea` and `gitea-runner`.

## Authentication

GitHub App credentials stored in a `arc-github-app` secret in the `arc-runner` namespace. Created via a new `github-runner-secret` task in `taskfiles/components.yaml` using the heredoc-to-kubectl pattern.

Required inputs:
- `GITHUB_APP_ID` — in `vars.yaml`
- `GITHUB_APP_INSTALLATION_ID` — in `vars.yaml`
- `github-app-key.pem` — local file (git-ignored), GitHub App private key

## Workflow Usage

```yaml
runs-on: arc-runner
```

## Components

```
cluster/apps/arc-controller/
  Chart.yaml          # depends on gha-runner-scale-set-controller 0.13.1
  values.yaml         # minimal operator config

cluster/apps/arc-runner/
  Chart.yaml          # depends on gha-runner-scale-set 0.13.1
  values.yaml         # githubConfigUrl, scaling, kubernetes mode

cluster/groups/services/values.yaml  # add arc-controller + arc-runner entries
```

## Decisions

- **Kubernetes container mode** over DinD — no Docker build needs, avoids privileged namespace.
- **GitHub App auth** over PAT — better security, higher rate limits, fine-grained permissions.
- **1 min / 5 max scaling** — keeps one runner warm to avoid cold-start delays, caps at 5 for homelab resource limits.
- **No persistent storage** — runners are ephemeral; workflow artifacts go to GitHub.
