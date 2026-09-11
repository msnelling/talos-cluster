# Cloudflare Tunnel

## Context

Seerr should be reachable from outside the LAN at `https://db3000.xmple.io`, and the same mechanism should later publish other apps (Gitea is the obvious next one), optionally behind Cloudflare Access. The cluster has no inbound path from the internet today, and opening one on the router is not wanted.

A Cloudflare Tunnel gives an outbound-only connection from the cluster to Cloudflare's edge; public hostnames are proxied CNAMEs to the tunnel. No port forward, no public IP.

## Design

### Chart

`cluster/apps/cloudflared/` is a chart of plain templates with no upstream dependency, in the `networking` group, namespace `cloudflared`.

The official charts were ruled out:
- `cloudflare/cloudflare-tunnel` (0.3.2) ships appVersion 2024.8.3 and has not been released since.
- `cloudflare/cloudflare-tunnel-remote` runs the `latest` tag.

The image is pinned in `values.yaml` with `registry`/`repository`/`tag` side by side so Renovate tracks it.

| Template | Purpose |
|---|---|
| `configmap.yaml` | `config.yaml` rendered from `values.ingress`, always ending in the `http_status:404` catch-all cloudflared requires |
| `deployment.yaml` | 2 replicas spread across nodes, `TUNNEL_TOKEN` from the secret, readiness on `/ready`, restricted security context |
| `pdb.yaml` | `minAvailable: 1`, rendered only with more than one replica so drains are never blocked |
| `podmonitor.yaml` | Scrapes `/metrics` on port 2000 |
| `prometheusrule.yaml` | `CloudflaredTunnelDown` when no replica holds an edge connection, or none is scraped |

### Tunnel mode: locally-managed

Ingress rules live in git. cloudflared only uses its config file for a **locally-managed** tunnel; a tunnel created in the Zero Trust dashboard is remotely managed, ignores the local ingress rules and takes its routes from the dashboard instead. It still connects and reports healthy, so the mismatch is silent, and there is no conversion from remote to local. The tunnel must therefore be created with the CLI.

The pods authenticate with the tunnel's token (`TUNNEL_TOKEN`) rather than a credentials JSON. The token carries the same account, tunnel ID and secret, and it keeps the secret a single string in `vars.yaml` like every other credential here.

### Routing: straight to the Service

Each route targets the app's Service, not Traefik. Inside the LAN, `db3000.xmple.io` carries Radarr, Sonarr, Prowlarr and the rest on subpaths. Forwarding the public hostname to Traefik would publish all of them; forwarding it to `seerr.db3000.svc` publishes Seerr and nothing else, whatever path is requested.

The Seerr HTTPRoute stays: LAN clients keep using it.

### DNS

- **Public:** `cloudflared tunnel route dns` creates a proxied CNAME `db3000 → <tunnel-id>.cfargotunnel.com` in the `xmple.io` zone. Before this change the zone had no `db3000` record and no wildcard.
- **LAN:** AdGuard forwards `xmple.io` to the router (`[/xmple.io/]10.1.1.1`), which answers `db3000 → traefik-gw → 10.1.1.60`. The public record never reaches LAN clients, so they keep going direct to Traefik. This split is intended; don't "fix" it.

Every new hostname needs its own `route dns`: the ingress rule alone does not create the record.

### Cloudflare Access

Access is configured per hostname at the edge (Zero Trust → Access → Applications). The chart supports it with an optional per-route `access.audTag`, plus the global `access.teamName`. With both set, cloudflared rejects any request without a valid Access JWT for that application. So if the Access application is ever deleted or its policy loosened by mistake, the origin still refuses the request instead of silently falling open.

Seerr does **not** use Access. Its own Plex/Jellyfin sign-in is the authentication, and an Access interstitial breaks that flow and the mobile apps. Access suits browser-only admin apps. For Gitea, note that `git` over HTTPS cannot complete an Access login: it needs a service token or `cloudflared access`, and SSH over the tunnel needs `cloudflared access ssh` on the client.

## One-time setup

```bash
brew install cloudflared
cloudflared tunnel login                     # browser; pick the xmple.io zone, writes ~/.cloudflared/cert.pem
cloudflared tunnel create lenovo
cloudflared tunnel route dns lenovo db3000.xmple.io
cloudflared tunnel token lenovo              # → cloudflare_tunnel_token in vars.yaml
task components:cloudflared-secret
```

Merge the PR; ArgoCD creates the namespace and deployment.

### After deploy

- Seerr → Settings → General → **Enable Proxy Support**, so it takes the client address from `X-Forwarded-For` rather than logging every request as the cloudflared pod.
- Seerr → Settings → General → **Application URL** should be `https://db3000.xmple.io` (used in notification links).

## Adding a hostname

1. Add `{hostname, service}` to `ingress` in `cluster/apps/cloudflared/values.yaml`, pointing at the app's Service (`http://<svc>.<ns>.svc:<port>`). Gitea's `gitea-http` is headless, so `http://gitea-http.gitea.svc:3000` resolves to the pod IPs directly — that works.
2. `cloudflared tunnel route dns lenovo <hostname>`.
3. Optionally create an Access application for the hostname and set `access.audTag` (and `access.teamName` once).

## Verification

- `kubectl logs -n cloudflared deploy/cloudflared` shows four `Registered tunnel connection` lines per replica.
- From off the LAN: `https://db3000.xmple.io` serves Seerr, and `https://db3000.xmple.io/radarr` is Seerr's 404, not Radarr.
- `dig db3000.xmple.io @10.1.1.53` still answers `10.1.1.60`.
