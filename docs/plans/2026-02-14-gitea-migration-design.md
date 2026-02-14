# Gitea Migration Design

## Overview

Migrate the Gitea instance from the legacy cluster (msnelling/argocd-bootstrap) to the Lenovo Talos cluster. The git data has been restored to a Longhorn volume and the PostgreSQL database is already restored to the external server.

## Source Analysis

The legacy Gitea deployment uses:
- Helm chart: gitea/gitea v12.5.0 (app version 1.22.1)
- External PostgreSQL database
- Longhorn 20Gi PVC (`gitea-shared-storage`, RWX, 2x replication)
- Valkey (Redis-compatible) for cache and session storage
- MinIO S3 for Gitea Actions artifact storage
- GitHub OAuth2, SMTP (smtp.mail.me.com), Gitea Actions enabled
- Vault + External Secrets Operator for secret management

## Target Architecture

### Placement

`cluster/apps/gitea/` — wrapper Helm chart following the same pattern as all other cluster apps. Auto-discovered by the existing `cluster-apps` ApplicationSet via `config.json`.

### Chart

Upstream dependency: `gitea/gitea` v12.5.0 from `https://dl.gitea.com/charts/`. Same chart version as legacy to minimize migration surprises — upgrade to latest can happen after migration is validated.

### Namespace

`gitea` — created automatically by ArgoCD's `CreateNamespace=true` sync option.

### Storage

- **Git data:** Restored Longhorn volume `gitea-shared-storage` (20Gi). The wrapper chart creates a PV + PVC in `templates/` that binds to this volume, then the Helm chart mounts it via `persistence.claimName` with `persistence.create: false`.
- **Database:** External PostgreSQL. Both `postgresql-ha` and `postgresql` sub-charts disabled. Connection configured via `gitea.config.database` with credentials from a Kubernetes secret.
- **Cache/Sessions:** Valkey standalone sub-chart (not cluster mode — overkill for a personal instance). 1Gi storage.
- **Actions artifacts:** MinIO S3 at `s3.xmple.io:9001`. Configured in `gitea.config.storage` with credentials from a Kubernetes secret.

### Networking

**HTTPS:**
- HTTPRoute in the gitea namespace: `gitea.xmple.io` → `gitea-http:3000`
- References `traefik-gateway` in traefik namespace (existing shared gateway)
- TLS terminated by the existing wildcard certificate on the gateway

**SSH:**
- Dedicated Cilium LoadBalancer IP on port 22
- `service.ssh.type: LoadBalancer` with `loadBalancerClass: io.cilium/l2-announcer`
- New `CiliumLoadBalancerIPPool` added to `cluster/apps/cilium/templates/ip-pool.yaml`
- Service label for pool selector matching
- DNS: separate A record for `gitea.xmple.io` pointing to the SSH LB IP, or SSH config alias. The HTTPS traffic still routes through the wildcard DNS → Traefik at 10.1.1.60.

Note: Since `gitea.xmple.io` resolves to Traefik's IP (10.1.1.60) via the wildcard DNS, SSH connections to `gitea.xmple.io:22` won't reach Gitea's LB IP. Options:
1. Override `gitea.xmple.io` DNS to point to the Gitea SSH IP, and rely on Traefik's hostname matching for HTTPS (both IPs serve HTTPS, but only Gitea's IP serves SSH)
2. Use `ssh.gitea.xmple.io` as a dedicated SSH hostname
3. Use the raw IP in SSH config

The simplest approach: set `gitea.xmple.io` DNS A record to the Gitea SSH IP. HTTPS still works because the wildcard `*.xmple.io` cert is on Traefik, and Traefik's IP also matches — but actually, if `gitea.xmple.io` points to the Gitea LB IP, HTTPS traffic won't reach Traefik. So we need either a dedicated SSH hostname or SSH config. Recommend `ssh.gitea.xmple.io` pointing to the Gitea SSH IP.

### Secrets

New Taskfile task `components:gitea-secrets` creates the gitea namespace and secrets from `vars.yaml`:

| Secret | Keys | Purpose |
|--------|------|---------|
| `gitea-postgres-secret` | `database__HOST`, `database__NAME`, `database__USER`, `database__PASSWD` | PostgreSQL connection |
| `gitea-admin-secret` | `username`, `password` | Admin user credentials |
| `gitea-oauth-secret` | `key`, `secret` | GitHub OAuth2 client |
| `gitea-smtp-secret` | `smtp__USER`, `smtp__PASSWD` | Email sending |
| `gitea-minio-secret` | `storage__MINIO_ACCESS_KEY_ID`, `storage__MINIO_SECRET_ACCESS_KEY` | S3 artifact storage |

Secrets with `section__KEY` naming use Gitea's `additionalConfigSources` to inject into app.ini sections.

### Configuration (app.ini via Helm values)

Non-sensitive config in `values.yaml` under `gitea.config`:

```yaml
gitea:
  config:
    server:
      DOMAIN: gitea.xmple.io
      ROOT_URL: https://gitea.xmple.io/
      SSH_DOMAIN: ssh.gitea.xmple.io
      SSH_PORT: 22
      SSH_LISTEN_PORT: 2222  # rootless image listens on 2222
    database:
      DB_TYPE: postgres
    service:
      DISABLE_REGISTRATION: true
    migrations:
      ALLOWED_DOMAINS: "github.com,*.github.com"
    actions:
      ENABLED: true
      DEFAULT_ACTIONS_URL: github
    storage:
      STORAGE_TYPE: minio
      MINIO_ENDPOINT: s3.xmple.io:9001
    mailer:
      ENABLED: true
      SMTP_ADDR: smtp.mail.me.com
      SMTP_PORT: 587
      PROTOCOL: smtp+starttls
      FROM: '"Gitea" <noreply@xmple.io>'
```

Sensitive values (DB credentials, OAuth secrets, SMTP password, MinIO keys) injected via `gitea.additionalConfigSources` referencing Kubernetes secrets.

### OAuth2

Configured via `gitea.oauth` list in values:
```yaml
gitea:
  oauth:
    - name: GitHub
      provider: github
      existingSecret: gitea-oauth-secret
```

## Files to Create

| File | Description |
|------|-------------|
| `cluster/apps/gitea/Chart.yaml` | Wrapper chart, depends on gitea/gitea v12.5.0 |
| `cluster/apps/gitea/values.yaml` | All configuration nested under `gitea:` |
| `cluster/apps/gitea/config.json` | `{"appName": "gitea", "namespace": "gitea", "chartPath": "cluster/apps/gitea"}` |
| `cluster/apps/gitea/templates/httproute.yaml` | HTTPRoute for gitea.xmple.io |
| `cluster/apps/gitea/templates/pv.yaml` | PV binding to restored Longhorn volume |

## Files to Modify

| File | Change |
|------|--------|
| `cluster/apps/cilium/templates/ip-pool.yaml` | Add `gitea-pool` with dedicated IP |
| `taskfiles/components.yaml` | Add `gitea-secrets` task |
| `vars.yaml.example` | Add gitea secret placeholders |

## Migration Sequence

1. Add gitea vars to `vars.yaml`
2. Run `task components:gitea-secrets` to create namespace and secrets
3. Create all chart files, commit and push to git
4. ArgoCD auto-discovers and syncs the gitea app
5. Gitea starts, connects to restored PostgreSQL, mounts restored git data
6. Verify: web UI loads, repos visible, push/pull over HTTPS and SSH, Actions work, OAuth login works

## Open Questions

- Exact Gitea SSH LoadBalancer IP (needs to be outside Traefik's pool)
- Whether to use `ssh.gitea.xmple.io` or another approach for SSH hostname
- Whether the restored Longhorn volume needs any ownership/permission adjustments for the rootless Gitea image (UID 1000)
