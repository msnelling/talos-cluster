# ArgoCD GitOps Design

## Goal

Add ArgoCD to the cluster and migrate all existing components (Cilium, Traefik, cert-manager) to GitOps management. Git becomes the single source of truth for the cluster state, with auto-sync and self-heal enforcing full GitOps discipline.

## Context

- Single-node Talos v1.12.3 cluster, Kubernetes v1.35.0
- Cilium, Traefik (Gateway API), and cert-manager already deployed via Taskfile + Helm
- Directory layout `cluster/apps/<name>/` already designed for ArgoCD adoption
- Domain `*.xmple.io` via Cloudflare, LoadBalancer IP `10.1.1.60`
- Private GitHub repository (`git@github.com:xmple/talos-cluster.git`)

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Adoption scope | All components including ArgoCD itself | Full GitOps — single pane of glass for everything in-cluster |
| App pattern | ApplicationSet (git files generator) | Auto-discovers apps via `cluster/apps/*/config.json`, each app declares its own namespace |
| App source format | Wrapper Helm charts | Each app has a `Chart.yaml` with upstream dependency + `values.yaml` + optional `templates/` for raw manifests |
| Sync policy | Auto-sync + self-heal + prune | Full GitOps discipline — git is the single source of truth |
| UI access | HTTPRoute via Traefik Gateway API | TLS via Let's Encrypt wildcard on `*.xmple.io` |
| Gateway | Shared wildcard `*.xmple.io` Gateway | Lives in Traefik chart, reusable across all future HTTPRoutes |
| Repo access | GitHub deploy key (SSH) | Read-only, created as a labeled Secret that ArgoCD auto-discovers |
| ArgoCD bootstrap | Taskfile task (same pattern as Cilium) | Required for first install; ArgoCD manages itself for subsequent upgrades |

## Bootstrap Order

```
task setup (updated)
  → ... → kubeconfig
  → cilium          (Helm wrapper chart)
  → traefik         (Helm wrapper chart)
  → cert-manager    (Helm wrapper chart + Cloudflare secret)
  → argocd          (Helm wrapper chart + deploy key secret + ApplicationSet)
  → health check
```

After ArgoCD starts, it discovers the ApplicationSet and takes over sync of all apps including itself. Future changes go through git.

## App Discovery via config.json

Each app has a `config.json` that the ApplicationSet's git files generator reads to determine the app name, target namespace, and chart path. This avoids deriving namespace from directory name, which breaks for apps like Cilium that must run in `kube-system`.

```json
{"appName": "cilium", "namespace": "kube-system", "chartPath": "cluster/apps/cilium"}
```

**Important:** The field is named `chartPath` (not `path`) because the git files generator injects its own `path` object that would collide.

## Wrapper Chart Structure

Each app under `cluster/apps/<name>/` is a self-contained Helm chart wrapping the upstream dependency:

```
cluster/apps/<name>/
  Chart.yaml        # Wrapper with upstream dependency
  values.yaml       # Values nested under dependency name
  config.json       # ArgoCD app metadata (name, namespace, chartPath)
  templates/        # Optional raw manifests (applied by Helm alongside the dependency)
```

Values must be nested under the dependency name (e.g., `cilium:`, `traefik:`, `argo-cd:`) since Helm scopes values to the dependency alias.

## ArgoCD — `cluster/apps/argocd/`

### `Chart.yaml`
```yaml
apiVersion: v2
name: argocd
version: 0.1.0
dependencies:
  - name: argo-cd
    version: "9.4.1"
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
```

`server.insecure: true` because TLS terminates at Traefik, not at ArgoCD.

Repository credentials are not configured in values — the deploy key is created as a Kubernetes Secret with the `argocd.argoproj.io/secret-type=repository` label, which ArgoCD auto-discovers.

### `templates/app-project.yaml`

Scoped AppProject for all cluster infrastructure apps. Uses `helm.sh/hook: post-install,post-upgrade` annotation so it's applied after ArgoCD CRDs are available.

### `templates/applicationset.yaml`

Uses `helm.sh/hook: post-install,post-upgrade` with weight `1` (after AppProject). The git files generator scans `cluster/apps/*/config.json`:

```yaml
generators:
  - git:
      repoURL: git@github.com:xmple/talos-cluster.git
      revision: main
      files:
        - path: cluster/apps/*/config.json
template:
  metadata:
    name: "{{.appName}}"
  spec:
    source:
      path: "{{.chartPath}}"
    destination:
      namespace: "{{.namespace}}"
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
      syncOptions:
        - CreateNamespace=true
```

Go template expressions are escaped with backtick syntax (`` {{ `{{.appName}}` }} ``) so Helm passes them through to ArgoCD.

### `templates/httproute.yaml`

Routes `argocd-beta.xmple.io` to `argocd-server` on port 80 (plain HTTP, since ArgoCD runs in insecure mode).

## Shared Wildcard Gateway — `cluster/apps/traefik/templates/gateway.yaml`

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
      port: 8443
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
      port: 8000
      hostname: "*.xmple.io"
      allowedRoutes:
        namespaces:
          from: All
```

**Important:** Listener ports must match Traefik's internal entrypoint ports (8443/8000), not the Service ports (443/80). Traefik maps entrypoints by container port, not service port.

cert-manager's gateway-shim watches for the `cert-manager.io/cluster-issuer` annotation and auto-creates a wildcard Certificate.

## cert-manager Gateway API Support

cert-manager requires explicit Gateway API enablement via file-based config (the `ExperimentalGatewayAPISupport` feature gate is deprecated):

```yaml
cert-manager:
  crds:
    enabled: true
  config:
    apiVersion: controller.config.cert-manager.io/v1alpha1
    kind: ControllerConfiguration
    enableGatewayAPI: true
```

## Taskfile Changes

Each task uses `helm repo add` + `helm dependency build` + `helm upgrade --install` with the local wrapper chart path. The `helm repo add` is required before `helm dependency build`.

The `argocd` task additionally:
1. Creates the argocd namespace
2. Checks for the `argocd-repo-key` file (fails with instructions if missing)
3. Creates the deploy key Secret with `argocd.argoproj.io/secret-type=repository` label
4. Builds and installs the chart

## Helm Adoption of Existing Resources

Resources originally created by `kubectl apply` (CiliumLoadBalancerIPPool, CiliumL2AnnouncementPolicy, ClusterIssuer) must be labeled for Helm adoption before the first wrapper chart install:

```bash
kubectl annotate <resource> meta.helm.sh/release-name=<release> meta.helm.sh/release-namespace=<ns> --overwrite
kubectl label <resource> app.kubernetes.io/managed-by=Helm --overwrite
```

This is a one-time migration step.

## File Layout

```
cluster/apps/
  cilium/
    Chart.yaml
    values.yaml
    config.json             {"appName": "cilium", "namespace": "kube-system", ...}
    templates/
      ip-pool.yaml
      l2-policy.yaml
  traefik/
    Chart.yaml
    values.yaml
    config.json             {"appName": "traefik", "namespace": "traefik", ...}
    templates/
      gateway.yaml          (shared wildcard *.xmple.io Gateway)
  cert-manager/
    Chart.yaml
    values.yaml
    config.json             {"appName": "cert-manager", "namespace": "cert-manager", ...}
    templates/
      cluster-issuer.yaml
  argocd/
    Chart.yaml
    values.yaml
    config.json             {"appName": "argocd", "namespace": "argocd", ...}
    templates/
      app-project.yaml
      applicationset.yaml
      httproute.yaml
```

## Secrets (Not in Git)

| Secret | Namespace | Created by |
|---|---|---|
| `cloudflare-api-token` | cert-manager | `task cert-manager` |
| `argocd-repo-key` | argocd | `task argocd` (from local `argocd-repo-key` file) |

The deploy key is generated once with `ssh-keygen -t ed25519 -f argocd-repo-key -N ""` and the public key is added as a read-only deploy key in GitHub repo settings.

## DNS (Manual)

Wildcard A record in Cloudflare:
```
*.xmple.io  →  10.1.1.60
```

## Day-2 Operations

### Upgrade any component
1. Bump the version in `Chart.yaml` dependencies
2. Push to `main`
3. ArgoCD auto-syncs the change

### Add a new workload
1. Create `cluster/apps/<name>/` with `Chart.yaml`, `values.yaml`, and `config.json`
2. Push to `main`
3. ApplicationSet auto-discovers and creates the Application

### Retrieve ArgoCD admin password
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Access ArgoCD UI
Navigate to `https://argocd-beta.xmple.io` and log in with username `admin` and the password above.
