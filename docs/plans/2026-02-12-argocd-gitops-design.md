# ArgoCD GitOps Design

## Goal

Add ArgoCD to the cluster and migrate all existing components (Cilium, Traefik, cert-manager) to GitOps management. Git becomes the single source of truth for the cluster state, with auto-sync and self-heal enforcing full GitOps discipline.

## Context

- Single-node Talos v1.12.3 cluster, Kubernetes v1.35.0
- Cilium, Traefik (Gateway API), and cert-manager already deployed via Taskfile + Helm
- Directory layout `cluster/apps/<name>/` already designed for ArgoCD adoption
- Domain `*.xmple.io` via Cloudflare, LoadBalancer IP `10.1.1.60`
- Private GitHub repository

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Adoption scope | All components | Full GitOps — single pane of glass for everything in-cluster |
| App pattern | ApplicationSet (git directory generator) | Auto-discovers `cluster/apps/*/`, zero boilerplate to add new apps |
| App source format | Wrapper Helm charts | Each app has a `Chart.yaml` with upstream dependency + `values.yaml` + optional `templates/` for raw manifests |
| Sync policy | Auto-sync + self-heal + prune | Full GitOps discipline — git is the single source of truth |
| UI access | HTTPRoute via Traefik Gateway API | TLS via Let's Encrypt wildcard on `*.xmple.io` |
| Gateway | Shared wildcard `*.xmple.io` Gateway | Reusable across all future HTTPRoutes |
| Repo access | GitHub deploy key (SSH) | Read-only, scoped to this repo |
| ArgoCD bootstrap | Taskfile task (same pattern as Cilium) | ArgoCD can't manage itself on first boot |

## Bootstrap Order

```
task setup (updated)
  → ... → kubeconfig
  → cilium          (Helm wrapper chart)
  → traefik         (Helm wrapper chart)
  → cert-manager    (Helm wrapper chart + Cloudflare secret)
  → argocd          (Helm wrapper chart + ApplicationSet + HTTPRoute)
  → health check
```

After ArgoCD starts, it discovers the ApplicationSet and takes over sync of Cilium, Traefik, and cert-manager. Future changes to any component go through git.

## Migration: Existing Apps to Wrapper Charts

Each app under `cluster/apps/<name>/` gains a `Chart.yaml` wrapping the upstream chart as a dependency. Existing `resources/` directories (Kustomize) are replaced by `templates/` directories (plain manifests applied by Helm).

### Cilium — `cluster/apps/cilium/`

**New file — `Chart.yaml`:**
```yaml
apiVersion: v2
name: cilium
version: 0.1.0
dependencies:
  - name: cilium
    version: "1.19.0"
    repository: https://helm.cilium.io
```

**Modified — `values.yaml`:** All existing values nested under `cilium:` key:
```yaml
cilium:
  ipam:
    mode: kubernetes
  kubeProxyReplacement: true
  gatewayAPI:
    enabled: false
  securityContext:
    capabilities:
      ciliumAgent:
        - CHOWN
        - KILL
        - NET_ADMIN
        - NET_RAW
        - IPC_LOCK
        - SYS_ADMIN
        - SYS_RESOURCE
        - DAC_OVERRIDE
        - FOWNER
        - SETGID
        - SETUID
      cleanCiliumState:
        - NET_ADMIN
        - SYS_ADMIN
        - SYS_RESOURCE
  cgroup:
    autoMount:
      enabled: false
    hostRoot: /sys/fs/cgroup
  k8sServiceHost: localhost
  k8sServicePort: 7445
  operator:
    replicas: 1
  l2announcements:
    enabled: true
  externalIPs:
    enabled: true
```

**New directory — `templates/`** (replaces `resources/`):

`templates/ip-pool.yaml`:
```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 10.1.1.60
      stop: 10.1.1.60
```

`templates/l2-policy.yaml`:
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

**Removed:** `resources/` directory (kustomization.yaml, ip-pool.yaml, l2-policy.yaml).

### Traefik — `cluster/apps/traefik/`

**New file — `Chart.yaml`:**
```yaml
apiVersion: v2
name: traefik
version: 0.1.0
dependencies:
  - name: traefik
    version: "38.0.2"
    repository: https://traefik.github.io/charts
```

**Modified — `values.yaml`:** Existing values nested under `traefik:` key, plus the new shared Gateway:
```yaml
traefik:
  providers:
    kubernetesGateway:
      enabled: true
    kubernetesIngress:
      enabled: false
  gateway:
    enabled: false
  service:
    spec:
      loadBalancerClass: io.cilium/l2-announcer
```

**New — `templates/gateway.yaml`:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: traefik-gateway
  namespace: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  gatewayClassName: traefik
  listeners:
    - name: websecure
      protocol: HTTPS
      port: 443
      hostname: "*.xmple.io"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-xmple-io-tls
      allowedRoutes:
        namespaces:
          from: All
    - name: web
      protocol: HTTP
      port: 80
      hostname: "*.xmple.io"
      allowedRoutes:
        namespaces:
          from: All
```

### cert-manager — `cluster/apps/cert-manager/`

**New file — `Chart.yaml`:**
```yaml
apiVersion: v2
name: cert-manager
version: 0.1.0
dependencies:
  - name: cert-manager
    version: "v1.19.3"
    repository: https://charts.jetstack.io
```

**Modified — `values.yaml`:** Nested under `cert-manager:` key:
```yaml
cert-manager:
  crds:
    enabled: true
```

**New directory — `templates/`** (replaces `resources/`):

`templates/cluster-issuer.yaml`:
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

**Removed:** `resources/` directory (kustomization.yaml, cluster-issuer.yaml).

**Note:** The Cloudflare API token Secret is not stored in git (it contains a credential). The Taskfile `argocd` task creates it before ArgoCD syncs cert-manager, same as the current `cert-manager` task does today.

## New: ArgoCD — `cluster/apps/argocd/`

### `Chart.yaml`
```yaml
apiVersion: v2
name: argocd
version: 0.1.0
dependencies:
  - name: argo-cd
    version: "7.8.13"
    repository: https://argoproj.github.io/argo-helm
```

### `values.yaml`
```yaml
argo-cd:
  server:
    insecure: true
  configs:
    params:
      server.insecure: true
    repositories:
      lenovo:
        url: git@github.com:xmple/talos-cluster.git
        type: git
        sshPrivateKeySecret:
          name: argocd-repo-key
          key: sshPrivateKey
```

`server.insecure: true` because TLS terminates at Traefik, not at ArgoCD.

### `templates/app-project.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: cluster
  namespace: argocd
spec:
  description: Cluster infrastructure apps
  sourceRepos:
    - git@github.com:xmple/talos-cluster.git
  destinations:
    - namespace: "*"
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
```

### `templates/applicationset.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: git@github.com:xmple/talos-cluster.git
        revision: main
        directories:
          - path: cluster/apps/*
          - path: cluster/apps/argocd
            exclude: true
  template:
    metadata:
      name: "{{.path.basename}}"
    spec:
      project: cluster
      source:
        repoURL: git@github.com:xmple/talos-cluster.git
        targetRevision: main
        path: "{{.path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

ArgoCD is excluded from the ApplicationSet to avoid chicken-and-egg issues — it's managed by the Taskfile bootstrap only.

### `templates/httproute.yaml`
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - argocd-beta.xmple.io
  rules:
    - backendRefs:
        - name: argocd-server
          port: 443
```

## vars.yaml Addition

```yaml
argocd_version: "7.8.13"
```

## Taskfile Changes

### New variable
```yaml
ARGOCD_VERSION:
  sh: yq '.argocd_version' vars.yaml
```

### New task: `argocd`

```yaml
argocd:
  desc: Install or upgrade ArgoCD
  deps: [_require-helm]
  cmds:
    - helm dependency build cluster/apps/argocd
    - helm upgrade --install argocd cluster/apps/argocd
        --namespace argocd
        --create-namespace
        --wait --timeout 5m
```

### Updated task: `setup`

Add `argocd` as the final step before the health check:
```
→ cilium → traefik → cert-manager → argocd → health check
```

### Updated existing tasks: `cilium`, `traefik`, `cert-manager`

Replace `helm repo add` + `helm upgrade --install <remote-chart>` with `helm dependency build` + `helm upgrade --install <local-path>` since they're now wrapper charts:

```yaml
cilium:
  desc: Install or upgrade Cilium CNI
  deps: [_require-helm]
  cmds:
    - helm dependency build cluster/apps/cilium
    - helm upgrade --install cilium cluster/apps/cilium
        --namespace kube-system
        --wait --timeout 5m
```

Same pattern for traefik and cert-manager. The `kubectl apply -k` steps are removed since the raw manifests are now in `templates/`.

### Secrets not in git

Two secrets must be created before ArgoCD can function:

1. **Cloudflare API token** (already exists from current `cert-manager` task):
   ```bash
   kubectl create secret generic cloudflare-api-token \
     --namespace cert-manager \
     --from-literal=api-token=<token>
   ```

2. **GitHub deploy key** (new):
   ```bash
   ssh-keygen -t ed25519 -f argocd-repo-key -N ""
   kubectl create secret generic argocd-repo-key \
     --namespace argocd \
     --from-file=sshPrivateKey=argocd-repo-key
   ```
   The public key is added as a deploy key in the GitHub repo settings (read-only).

Both are created by the Taskfile `argocd` task before the `helm upgrade --install`.

## File Layout (Final)

```
cluster/apps/
  cilium/
    Chart.yaml              (new — wrapper)
    values.yaml             (modified — nested under cilium:)
    templates/
      ip-pool.yaml          (moved from resources/)
      l2-policy.yaml        (moved from resources/)
  traefik/
    Chart.yaml              (new — wrapper)
    values.yaml             (modified — nested under traefik:)
    templates/
      gateway.yaml          (new — shared wildcard Gateway)
  cert-manager/
    Chart.yaml              (new — wrapper)
    values.yaml             (modified — nested under cert-manager:)
    templates/
      cluster-issuer.yaml   (moved from resources/)
  argocd/
    Chart.yaml              (new)
    values.yaml             (new)
    templates/
      app-project.yaml      (new)
      applicationset.yaml   (new)
      httproute.yaml        (new)
```

**Removed:**
- `cluster/apps/cilium/resources/` (replaced by `templates/`)
- `cluster/apps/cert-manager/resources/` (replaced by `templates/`)

## DNS (Manual)

Wildcard A record should already exist from the Traefik setup:
```
*.xmple.io  →  10.1.1.60
```

If not already created, add it in Cloudflare. `argocd-beta.xmple.io` resolves via the wildcard.

## Day-2 Operations

### Upgrade any component
1. Bump the version in `Chart.yaml` dependencies and `vars.yaml`
2. Push to `main`
3. ArgoCD auto-syncs the change

### Add a new workload
1. Create `cluster/apps/<name>/Chart.yaml` + `values.yaml`
2. Push to `main`
3. ApplicationSet auto-discovers and creates the Application

### Retrieve ArgoCD admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Access ArgoCD UI
Navigate to `https://argocd-beta.xmple.io` and log in with username `admin` and the password above.
