# Traefik Gateway API + TLS Design

## Goal

Add Traefik as the Gateway API controller with a Cilium-managed LoadBalancer IP, and cert-manager for automatic TLS certificates via Let's Encrypt + Cloudflare DNS-01. All services accessible at `*.xmple.io`.

## Context

- Single-node Talos cluster with Cilium CNI (kube-proxy replacement)
- Cilium provides LB-IPAM and L2 announcements for bare-metal LoadBalancer support
- LoadBalancer IP: `10.1.1.60` on the LAN subnet
- Domain: `*.xmple.io` managed via Cloudflare
- ArgoCD adoption planned for the future

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| LoadBalancer provider | Cilium LB-IPAM + L2 announcements | Already have Cilium; no need for MetalLB |
| LB class | `io.cilium/l2-announcer` | Proper service binding via loadBalancerClass, not deprecated loadBalancerIP field |
| Routing API | Gateway API only | Modern standard, no legacy Ingress |
| Ingress controller | Traefik | Rich middleware, dashboard, good Gateway API support |
| TLS | cert-manager + Let's Encrypt | Automatic issuance and renewal |
| ACME challenge | DNS-01 via Cloudflare | Works behind NAT, supports wildcards |
| Resource templating | Kustomize | Built into kubectl, ArgoCD-native, clean variable substitution |

## Components & Bootstrap Order

```
task setup (existing)
  → ... → kubeconfig
  → cilium          (Helm install + kubectl apply -k resources)
  → gateway-api     (install CRDs)
  → traefik         (Helm install)
  → cert-manager    (create secret + Helm install + kubectl apply -k resources)
  → health check
```

## Changes

### vars.yaml additions

```yaml
loadbalancer_ip: "10.1.1.60"
domain: "xmple.io"
traefik_version: "38.0.2"
gateway_api_version: "v1.4.1"
cert_manager_version: "v1.19.3"
cloudflare_api_token: "<token>"
```

### Updated: cluster/apps/cilium/

**values.yaml** — add:
```yaml
l2announcements:
  enabled: true
externalIPs:
  enabled: true
```

**resources/ip-pool.yaml:**
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 10.1.1.60
      stop: 10.1.1.60
```

**resources/l2-policy.yaml:**
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-policy
spec:
  interfaces:
    - ^eno.*
  externalIPs: true
  loadBalancerIPs: true
```

**resources/kustomization.yaml** — references ip-pool.yaml and l2-policy.yaml.

### New: cluster/apps/traefik/

**values.yaml:**
```yaml
providers:
  kubernetesGateway:
    enabled: true
  kubernetesIngress:
    enabled: false

service:
  spec:
    loadBalancerClass: io.cilium/l2-announcer
```

### New: cluster/apps/cert-manager/

**values.yaml:**
```yaml
crds:
  enabled: true
```

**resources/cluster-issuer.yaml:**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

**resources/kustomization.yaml** — references cluster-issuer.yaml.

### Taskfile additions

- `LOADBALANCER_IP`, `DOMAIN`, `TRAEFIK_VERSION`, `GATEWAY_API_VERSION`, `CERT_MANAGER_VERSION`, `CLOUDFLARE_API_TOKEN` vars from vars.yaml
- **`gateway-api`** task — `kubectl apply -f` upstream standard CRDs for the pinned version
- **`traefik`** task — `helm upgrade --install` with precondition for helm
- **`cert-manager`** task — creates Cloudflare API token secret + `helm upgrade --install` + `kubectl apply -k cluster/apps/cert-manager/resources/`
- Updated **`cilium`** task — adds `kubectl apply -k cluster/apps/cilium/resources/` after Helm install
- Updated **`setup`** flow — adds gateway-api, traefik, cert-manager steps after cilium

### File layout

```
cluster/apps/
  cilium/
    values.yaml
    resources/
      kustomization.yaml
      ip-pool.yaml
      l2-policy.yaml
  traefik/
    values.yaml
  cert-manager/
    values.yaml
    resources/
      kustomization.yaml
      cluster-issuer.yaml
```

## DNS (manual)

Create a wildcard A record in Cloudflare:

```
*.xmple.io  →  10.1.1.60
```

This is a one-time manual step outside the Taskfile automation.

## Day-2 Operations

### Upgrade Traefik
1. Bump `traefik_version` in vars.yaml
2. Run `task traefik`

### Upgrade cert-manager
1. Bump `cert_manager_version` in vars.yaml
2. Run `task cert-manager`

### Upgrade Gateway API CRDs
1. Bump `gateway_api_version` in vars.yaml
2. Run `task gateway-api`
