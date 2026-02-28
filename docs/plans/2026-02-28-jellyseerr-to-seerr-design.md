# Jellyseerr to Seerr Migration

## Context

Jellyseerr has been renamed to Seerr (merger of Overseerr + Jellyseerr). The `fallenbagel/jellyseerr` Docker image is dead-ended at v2.7.3. Version 3.x is published as `ghcr.io/seerr-team/seerr` with an official Helm chart at `oci://ghcr.io/seerr-team/seerr/seerr-chart`.

Renovate cannot auto-detect package renames, so the current Jellyseerr chart will never receive updates.

## Design

Replace the media-app library-based Jellyseerr chart with a wrapper chart around the official Seerr Helm chart.

### Chart Structure

```
cluster/db3000/seerr/
  Chart.yaml          # depends on seerr-chart v3.2.0 from OCI
  values.yaml         # config nested under seerr-chart:
  templates/pv.yaml   # static PV for existing Longhorn volume
```

### Routing

Uses the official chart's built-in HTTPRoute configured via values:
- parentRefs: `traefik-gateway` in `traefik` namespace, `sectionName: websecure`
- hostname: `db3000.xmple.io`
- path: `/` (PathPrefix)

### Persistence

The existing Longhorn volume `db3000-jellyseerr-config` keeps its name (no data copy). The wrapper chart creates a static PV referencing it. The official chart's PVC binds via `config.persistence.volumeName`.

### Database

PostgreSQL database name and user stay as `jellyseerr` in CNPG — these are just connection parameters. The Kubernetes secret is renamed from `jellyseerr-db-secrets` to `seerr-db-secrets` and referenced via `extraEnvFrom`.

### Image

No image tag override in values. The chart's `appVersion` controls the image version. Renovate tracks the chart version (which bumps appVersion), consistent with other wrapped charts (cilium, traefik, argocd).

## Changes

| File | Action | Detail |
|------|--------|--------|
| `cluster/db3000/seerr/Chart.yaml` | Create | Wrapper chart depending on seerr-chart OCI |
| `cluster/db3000/seerr/values.yaml` | Create | Chart config: route, persistence, env, resources |
| `cluster/db3000/seerr/templates/pv.yaml` | Create | Static PV for existing Longhorn volume |
| `cluster/db3000/jellyseerr/` | Delete | Old chart directory |
| `cluster/groups/db3000/values.yaml` | Edit | Replace jellyseerr entry with seerr |
| `taskfiles/components.yaml` | Edit | Rename secret to seerr-db-secrets |
| `vars.yaml.example` | Edit | Rename jellyseerr_postgres_password to seerr_postgres_password |
| `CLAUDE.md` | Edit | Update secrets table |

## Migration Notes

- Seerr auto-migrates from Jellyseerr on first startup (no manual DB migration needed)
- The Seerr container runs as non-root (UID 1000) — the official chart handles securityContext
- ArgoCD will prune the old jellyseerr resources and create new seerr resources
- The Longhorn volume data persists through the transition (PV has Retain reclaim policy)
- The user must update `vars.yaml` to rename `jellyseerr_postgres_password` to `seerr_postgres_password` and re-run `task components:db3000-secrets`
