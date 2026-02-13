# db3000 Media Apps Migration Design

## Overview

Port all 11 active media applications from the `msnelling/argocd-db3000` repository to this cluster. Apps are converted from Kustomize (base/overlays) to the wrapper Helm chart pattern used by this repo, auto-discovered by the existing ArgoCD ApplicationSet.

## Source

Old cluster: `admin@homelab` context, `db3000` namespace.
Old repo: `msnelling/argocd-db3000` (GitHub).

## Applications

| App | Image | Port | Config Size | Media | LB | Route |
|---|---|---|---|---|---|---|
| plex | ghcr.io/linuxserver/plex | 32400 | 50Gi | yes | yes (:32400) | `plex.xmple.io/` |
| jellyfin | ghcr.io/jellyfin/jellyfin | 8096 | 50Gi + 50Gi cache | yes | no | `db3000.xmple.io/jellyfin` |
| radarr | ghcr.io/linuxserver/radarr | 7878 | 1Gi | yes | no | `db3000.xmple.io/radarr` |
| sonarr | ghcr.io/linuxserver/sonarr | 8989 | 1Gi | yes | no | `db3000.xmple.io/sonarr` |
| bazarr | ghcr.io/linuxserver/bazarr | 6767 | 1Gi | yes | no | `db3000.xmple.io/bazarr` |
| transmission | ghcr.io/linuxserver/transmission | 9091 | 1Gi | yes (downloads) | yes (:51413) | `db3000.xmple.io/transmission` |
| prowlarr | ghcr.io/linuxserver/prowlarr | 9696 | 1Gi | no | no | `db3000.xmple.io/prowlarr` |
| nzbget | ghcr.io/nzbgetcom/nzbget | 6789 | 1Gi | yes (downloads) | no | `db3000.xmple.io/nzbget` |
| jellyseerr | fallenbagel/jellyseerr | 5055 | 5Gi | no | no | `db3000.xmple.io/` |
| tautulli | ghcr.io/linuxserver/tautulli | 8181 | 1Gi | no | no | `db3000.xmple.io/tautulli` |
| audiobookshelf | ghcr.io/advplyr/audiobookshelf | 80 | 1Gi | yes | no | `db3000.xmple.io/audiobookshelf` |

## Routing

All apps serve from `db3000.xmple.io/<app>/` via path-prefix HTTPRoutes through the existing shared `traefik-gateway`. Exceptions:

- **Plex** uses `plex.xmple.io/` — Plex cannot serve from a subpath.
- **Jellyseerr** serves at `db3000.xmple.io/` (root) as the landing page.

Both hostnames are covered by the existing `*.xmple.io` wildcard certificate. No TLS changes needed.

## Local Library Chart

All media apps share a common pattern: Deployment + Service + PVC + ConfigMap + HTTPRoute. A local library chart at `cluster/lib/media-app/` provides these templates, avoiding duplication across 11 apps.

### Structure

```
cluster/lib/media-app/
  Chart.yaml          # type: application, version: 0.1.0
  values.yaml         # defaults
  templates/
    _helpers.tpl
    deployment.yaml
    service.yaml
    configmap.yaml
    pvc.yaml
    httproute.yaml
```

### Values API

Each app's `Chart.yaml` declares it as a file dependency:

```yaml
dependencies:
  - name: media-app
    version: "0.1.0"
    repository: "file://../../lib/media-app"
```

Values are nested under `media-app:`:

```yaml
media-app:
  name: radarr
  image:
    repository: ghcr.io/linuxserver/radarr
    tag: "6.0.4"
  containerPort: 7878
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  envFromSecret: ""
  persistence:
    config:
      size: 1Gi
      mountPath: /config
    media:
      enabled: true
      mountPath: /media
      subPath: ""
  httproute:
    hostname: db3000.xmple.io
    path: /radarr
  service:
    port: 80
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 512Mi
```

Apps needing extras (LoadBalancer services, sidecars, extra volumes) add them in their own `templates/` directory alongside the library chart output.

## Media Storage

A dedicated app `cluster/apps/media-storage/` provides:

- **SMB CSI Driver** as a Helm dependency (`csi-driver-smb` chart).
- **PersistentVolume** template pointing at `//10.1.1.30/Media` with SMB mount options:
  - `dir_mode=0770`, `file_mode=0660`, `uid=568`, `gid=1001`
  - `forceuid`, `forcegid`, `mfsymlinks`, `nobrl`, `vers=3.0`
- **PersistentVolumeClaim** `media-share` in the `db3000` namespace (100Gi, RWX).

SMB credentials come from the `media-smb-creds` secret.

Apps that need media access set `persistence.media.enabled: true` in their values. The library chart mounts the `media-share` PVC at the configured `mountPath`.

## Config Storage

Each app gets its own Longhorn PVC using the default StorageClass (single replica, matching this cluster's single-node setup). No custom StorageClass — the existing Longhorn default is sufficient.

## Networking

### Cilium IP Pool

The existing pool (`10.1.1.60`) serves the shared Gateway. Plex and Transmission need LoadBalancer services for direct protocol access. Expand the Cilium IP pool to include `10.1.1.53` (carried over from the old cluster).

The two LoadBalancer services share `10.1.1.53` via `lbipam.cilium.io/sharing-key: db3000` annotation.

### Services

- Most apps: ClusterIP only (port 80 → container port).
- Plex: ClusterIP (32400) + LoadBalancer (32400) on 10.1.1.53.
- Transmission: ClusterIP (80 → 9091) + LoadBalancer (51413 TCP+UDP) on 10.1.1.53.

## Transmission (VPN Sidecar)

Transmission is the only multi-container app. It runs a Gluetun VPN sidecar for WireGuard-based VPN (Mullvad).

### Containers

1. **gluetun** — VPN client. Image: `qmcgaw/gluetun`. Ports: 8888 (HTTP proxy), 8000 (control). Requires `NET_ADMIN` capability and `/dev/net/tun` hostPath.
2. **transmission** — BitTorrent client. Image: `ghcr.io/linuxserver/transmission`. Port: 9091 (web UI), 51413 (BitTorrent).

### VPN Config (from old cluster)

ConfigMap env:
- `DOT: off`, `HTTPPROXY: on`, `UPDATER_PERIOD: 24h`
- `UPDATER_VPN_SERVICE_PROVIDERS: mullvad`, `WIREGUARD_MTU: 1420`
- `FIREWALL_INPUT_PORTS: 8000,8888,9091,51413`
- `HEALTH_TARGET_ADDRESS: 1.1.1.1:443`

Secret env: `VPN_SERVICE_PROVIDER`, `VPN_TYPE`, `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `SERVER_CITIES`.

Proxy credentials: `HTTPPROXY_USER`, `HTTPPROXY_PASSWORD`.

Auth config: `config.toml` mounted at `/gluetun/auth/config.toml`.

## Secrets

### Migration (One-Time)

Extract secret values from `admin@homelab` cluster and add to `vars.yaml`. This is a one-time implementation step.

### vars.yaml Additions

```yaml
# db3000 media apps
smb_username: ""
smb_password: ""
vpn_service_provider: ""
vpn_type: ""
vpn_wireguard_private_key: ""
vpn_wireguard_addresses: ""
vpn_server_cities: ""
vpn_proxy_user: ""
vpn_proxy_password: ""
vpn_auth_config: ""
```

### Taskfile Task

`task components:db3000-secrets` creates all db3000 secrets from `vars.yaml`:
- `media-smb-creds` (namespace: db3000) — username, password
- `transmission-vpn-secrets` (namespace: db3000) — VPN provider, type, WireGuard key, addresses, cities
- `transmission-proxy-credentials` (namespace: db3000) — proxy user, password
- `gluetun-auth-secrets` (namespace: db3000) — config.toml

This task runs in the bootstrap chain after namespace creation, before ArgoCD sync.

### Jellyseerr

The old cluster connected Jellyseerr to an external database via `jellyseerr-secrets` (DB_HOST, DB_NAME, etc.). On the new cluster, Jellyseerr uses its default embedded SQLite database. No database secret needed.

## Per-App Environment Variables

Most LinuxServer.io apps share the standard set:
```
TZ: Europe/London
PUID: 568
PGID: 1001
UMASK: 007
```

Exceptions:
- **Jellyfin**: `JELLYFIN_PublishedServerUrl: https://db3000.xmple.io/jellyfin`, `JELLYFIN_hostwebclient: true`
- **Jellyseerr**: `TZ: Europe/London` only
- **Audiobookshelf**: `TZ: Europe/London`, `CONFIG_PATH: /data/config`, `METADATA_PATH: /data/metadata`, `BACKUP_PATH: /data/backups`

## Per-App Resource Limits

| App | CPU Request | Memory Request | Memory Limit |
|---|---|---|---|
| plex | 100m | 2Gi | 2Gi |
| jellyfin | 100m | 4Gi | 4Gi |
| radarr | 100m | 512Mi | 512Mi |
| sonarr | 100m | 600Mi | 600Mi |
| bazarr | 100m | 500Mi | 500Mi |
| transmission | 50m | 1500Mi | 1500Mi |
| gluetun (sidecar) | 100m | — | — |
| prowlarr | 100m | 384Mi | 384Mi |
| nzbget | 100m | 300Mi | 300Mi |
| jellyseerr | 100m | 1Gi | 1Gi |
| tautulli | 100m | 600Mi | 600Mi |
| audiobookshelf | 100m | 512Mi | 512Mi |

## Directory Structure

```
cluster/
  lib/
    media-app/
      Chart.yaml
      values.yaml
      templates/
        _helpers.tpl
        deployment.yaml
        service.yaml
        configmap.yaml
        pvc.yaml
        httproute.yaml
  apps/
    media-storage/
      Chart.yaml            # depends on csi-driver-smb
      values.yaml
      config.json
      templates/
        namespace.yaml      # db3000 namespace
        pv.yaml
        pvc.yaml
    plex/
      Chart.yaml
      values.yaml
      config.json
      templates/
        service-lb.yaml     # LoadBalancer for :32400
    jellyfin/
      Chart.yaml
      values.yaml
      config.json
      templates/
        pvc-cache.yaml      # extra 50Gi cache volume
    radarr/
      Chart.yaml
      values.yaml
      config.json
    sonarr/
      Chart.yaml
      values.yaml
      config.json
    bazarr/
      Chart.yaml
      values.yaml
      config.json
    transmission/
      Chart.yaml
      values.yaml
      config.json
      templates/
        service-lb.yaml     # LoadBalancer for :51413
    prowlarr/
      Chart.yaml
      values.yaml
      config.json
    nzbget/
      Chart.yaml
      values.yaml
      config.json
    jellyseerr/
      Chart.yaml
      values.yaml
      config.json
    tautulli/
      Chart.yaml
      values.yaml
      config.json
    audiobookshelf/
      Chart.yaml
      values.yaml
      config.json
```

## Changes to Existing Resources

1. **Cilium IP pool** (`cluster/apps/cilium/templates/ip-pool.yaml`): Expand to include `10.1.1.53`.
2. **vars.yaml.example**: Add db3000 secret placeholders.
3. **Taskfile** (`taskfiles/components.yaml`): Add `db3000-secrets` task.
4. **CLAUDE.md**: Document new apps and secrets.
