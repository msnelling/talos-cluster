# Minecraft Bedrock Servers Design

## Overview

Migrate three Minecraft Bedrock Edition servers from the legacy `msnelling/minecraft` repository (Kustomize-based) into this cluster's wrapper Helm chart architecture with ArgoCD management.

## Servers

| Server | World Name | Game Mode | Seed | Port |
|--------|-----------|-----------|------|------|
| mc1 | My World | Creative | 7794572526148668328 | 19132 |
| mc2 | My World 2 | Creative | (random) | 19133 |
| mc3 | Survival World | Survival | (random) | 19134 |

All servers use the `itzg/minecraft-bedrock-server` image with allowlist for two players (Deddy, Luna).

## Architecture

### New ArgoCD Group: `games`

A new `games` group with a dedicated `minecraft` namespace, following the same pattern as the existing `db3000` group but without privileged PodSecurity (Minecraft runs unprivileged).

### Library Chart: `cluster/lib/minecraft-server/`

Reusable library chart providing templates for Minecraft Bedrock servers, mirroring the `media-app` library pattern:

**Templates:**
- `_helpers.tpl` — Name, labels, selectorLabels. Hardcodes `app.kubernetes.io/part-of: minecraft`
- `deployment.yaml` — Single replica, Recreate strategy, envFrom ConfigMap, `/data` volume mount, liveness probe (`mc-monitor status-bedrock`), `tty: true` + `stdin: true`
- `service.yaml` — LoadBalancer with `loadBalancerClass: io.cilium/l2-announcer`, sharing key annotation, TCP+UDP dual ports
- `configmap.yaml` — Server config from `env` map
- `pvc.yaml` — Longhorn PVC (2Gi, Retain policy)
- `pv.yaml` — Optional pre-existing Longhorn volume binding for data migration

**Default values** include shared base environment variables:
- `EULA: "true"`, `TZ: Europe/London`, `VERSION: LATEST`
- `VIEW_DISTANCE: "32"`, `EMIT_SERVER_TELEMETRY: "true"`, `ENABLE_LAN_VISIBILITY: "true"`
- Resource defaults: 250m CPU request, 1Gi memory request/limit

### Per-Server Charts: `cluster/games/mc1/`, `mc2/`, `mc3/`

Thin wrapper charts referencing the library via `repository: "file://../../lib/minecraft-server"`. Each provides only server-specific values (game mode, world name, seed, port, allow list, ops).

### Networking

Direct Cilium LB-IPAM with a shared IP `10.1.1.52`:

- New `CiliumLoadBalancerIPPool` (`minecraft-pool`) in `cluster/apps/cilium/templates/ip-pool.yaml`
- IP range: `10.1.1.52 - 10.1.1.52`
- Service selector: `app.kubernetes.io/part-of: minecraft`
- All three servers share the IP via `lbipam.cilium.io/sharing-key: minecraft-lb`
- Each server on its own port (19132/19133/19134), both TCP and UDP

No Traefik involvement — game traffic goes directly to pods.

### ArgoCD Integration

- Group chart at `cluster/groups/games/` with `applications.yaml` and `namespace.yaml`
- New `app-group-games.yaml` in `cluster/apps/argocd/templates/`
- Sync policy: auto-sync + self-heal + prune + ServerSideApply (matching existing patterns)

## File Structure

```
cluster/
  lib/minecraft-server/
    Chart.yaml
    values.yaml
    templates/
      _helpers.tpl
      deployment.yaml
      service.yaml
      configmap.yaml
      pvc.yaml
      pv.yaml
  games/
    mc1/
      Chart.yaml
      values.yaml
    mc2/
      Chart.yaml
      values.yaml
    mc3/
      Chart.yaml
      values.yaml
  groups/games/
    Chart.yaml
    values.yaml
    templates/
      applications.yaml
      namespace.yaml
  apps/argocd/templates/
    app-group-games.yaml          # New file
  apps/cilium/templates/
    ip-pool.yaml                  # Add minecraft-pool entry
```

## Decisions

- **No Tailscale services** — LAN-only access via Cilium LB
- **No PodSecurity labels** — Minecraft containers run unprivileged
- **No media-app reuse** — media-app is HTTP-focused with hardcoded db3000 labels
- **Longhorn storage class** — reuse existing `longhorn` class, no custom storage class needed
- **Image tag `latest` with `Always` pull** — matches legacy setup for auto-updates
