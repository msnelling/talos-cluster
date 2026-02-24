# ArgoCD GitHub OAuth Authentication + URL Rename

## Overview

Add GitHub OAuth authentication to ArgoCD via Dex, restricting login to members of the `xmple` GitHub organization. All org members get admin access. Also rename the ArgoCD URL from `argocd-beta.xmple.io` to `argocd.xmple.io`.

## Why Dex

GitHub implements OAuth 2.0 but is not a standard OIDC provider (no `/.well-known/openid-configuration` endpoint). ArgoCD's built-in OIDC requires a compliant issuer. Dex bridges the gap — it's enabled by default in the argo-cd Helm chart and translates GitHub OAuth into OIDC that ArgoCD understands.

## Design

### Dex GitHub Connector

The connector authenticates users via GitHub OAuth and restricts access to `xmple` org members:

```yaml
dex.config: |
  connectors:
    - type: github
      id: github
      name: GitHub
      config:
        clientID: <from vars.yaml, committed in values.yaml>
        clientSecret: $dex.github.clientSecret
        orgs:
          - name: xmple
```

- `clientID` is not sensitive and lives directly in `values.yaml`
- `clientSecret` uses ArgoCD's `$key` syntax — resolved from `argocd-secret` at runtime
- The `orgs` filter denies authentication to non-members

### Secret Management

The `clientSecret` is injected via `--set` in the existing `task components:argocd` Helm command:

```
--set argo-cd.configs.secret.extra.dex\\.github\\.clientSecret={{.GITHUB_OAUTH_CLIENT_SECRET}}
```

This populates the `dex.github.clientSecret` key in the `argocd-secret` Kubernetes Secret. The chart's `configs.secret.extra` template base64-encodes the value automatically.

New vars in `vars.yaml`:
- `github_oauth_client_id` — GitHub OAuth App client ID
- `github_oauth_client_secret` — GitHub OAuth App client secret

### RBAC

Since Dex already restricts authentication to `xmple` org members, RBAC is simple:

```yaml
configs:
  rbac:
    policy.default: role:admin
    scopes: "[groups]"
```

All authenticated users (= all org members) get admin. No `policy.csv` rules needed.

### URL Rename

- `cluster/apps/argocd/templates/httproute.yaml`: `argocd-beta.xmple.io` → `argocd.xmple.io`
- `configs.cm.url`: `https://argocd.xmple.io` (required for Dex callback URL)

### GitHub OAuth App Setup (Manual)

Create at `https://github.com/organizations/xmple/settings/applications`:
- **Homepage URL:** `https://argocd.xmple.io`
- **Authorization callback URL:** `https://argocd.xmple.io/api/dex/callback`

## Files Changed

| File | Change |
|---|---|
| `cluster/apps/argocd/values.yaml` | Add `configs.cm.url`, `dex.config`, `configs.rbac`, clientID |
| `cluster/apps/argocd/templates/httproute.yaml` | Hostname `argocd-beta.xmple.io` → `argocd.xmple.io` |
| `taskfiles/components.yaml` | Add `--set` for clientSecret in argocd task |
| `vars.yaml.example` | Add `github_oauth_client_id`, `github_oauth_client_secret` |
| `CLAUDE.md` | Update secrets table with GitHub OAuth entries |

## DNS Prerequisite

Ensure `argocd.xmple.io` resolves to the load balancer IP (10.1.1.60). Either update the existing `argocd-beta` DNS record or create a new one.
