# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single-node Talos Linux Kubernetes cluster with full GitOps management via ArgoCD. All cluster components are deployed as **wrapper Helm charts** and managed declaratively through git.

**Stack:** Talos v1.12.3, Kubernetes v1.35.0, Cilium CNI, Traefik (Gateway API), cert-manager, Longhorn, ArgoCD

## Commands

### Bootstrap
```bash
task setup NODE_IP=x.x.x.x    # Full cluster bootstrap (generate → patch → apply → bootstrap → install all components)
```

### Individual Component Install/Upgrade
```bash
task cilium          # Install/upgrade Cilium CNI (kube-system)
task traefik         # Install/upgrade Traefik (traefik namespace)
task cert-manager    # Install/upgrade cert-manager (cert-manager namespace)
task longhorn         # Install/upgrade Longhorn (longhorn-system namespace)
task argocd          # Install/upgrade ArgoCD (argocd namespace)
```

Each task runs: `helm repo add` → `helm dependency build` → `helm upgrade --install` with `--force-conflicts` (required for Helm 4 SSA compatibility with ArgoCD).

### Day-2 Operations
```bash
task upgrade-talos   # Upgrade Talos OS
task upgrade-k8s     # Upgrade Kubernetes
task reconfigure     # Re-apply Talos config patches
task status          # Cluster health check
task dashboard       # Interactive Talos dashboard
```

After ArgoCD is running, component upgrades go through git: bump the version in `Chart.yaml`, push to `main`, ArgoCD auto-syncs.

### Bootstrap vs ArgoCD-Managed Components

Only components that must exist before ArgoCD belong in the Taskfile bootstrap chain (Cilium, Traefik, cert-manager). Other components (e.g., Longhorn) should have their namespace and secrets created during bootstrap, but the actual Helm install is left to ArgoCD. ArgoCD handles CRD-before-CR ordering natively, which avoids Helm's inability to install custom resources alongside the CRDs that define them.

## Architecture

### Wrapper Helm Chart Pattern

Every component under `cluster/apps/<name>/` is a self-contained Helm chart wrapping an upstream dependency:

```
cluster/apps/<name>/
  Chart.yaml        # Declares upstream chart as dependency with pinned version
  values.yaml       # Config nested under dependency name (e.g., cilium:, traefik:, argo-cd:)
  config.json       # ArgoCD app metadata: {"appName", "namespace", "chartPath"}
  templates/        # Optional raw K8s manifests deployed alongside the dependency
```

**Values nesting is mandatory** — Helm scopes values to the dependency alias. A Traefik value goes under `traefik:`, Cilium under `cilium:`, ArgoCD under `argo-cd:`.

### ArgoCD GitOps Flow

**ApplicationSet** (git files generator) scans `cluster/apps/*/config.json` to auto-discover apps. Each config.json declares the app name, target namespace, and chart path.

**ArgoCD self-management** is handled separately via a dedicated `Application` resource (not the ApplicationSet) with `prune: false` to prevent ArgoCD from ever deleting its own resources.

**Sync policy:** All apps use auto-sync + self-heal + ServerSideApply. Non-ArgoCD apps also have prune enabled.

### Networking Stack

```
Client → DNS (*.xmple.io → 10.1.1.60) → Cilium LB-IPAM (L2 announcement)
  → Traefik Service (80/443) → Traefik container (8000/8443)
  → HTTPRoute matching → Backend Service
```

- **Cilium** provides LoadBalancer IPs via LB-IPAM + L2 announcements (no MetalLB needed)
- **Traefik** is the Gateway API controller; shared wildcard Gateway in traefik namespace
- **cert-manager** watches Gateway annotations and auto-creates wildcard certificates via Cloudflare DNS-01

### Configuration

`vars.yaml` (git-ignored) holds all cluster config: node IP, versions, secrets. See `vars.yaml.example` for structure.

`factory.yaml` defines the custom Talos image with extensions (Tailscale, Intel microcode, iSCSI).

## Working with ArgoCD

**Always push changes to git before expecting ArgoCD to sync them.** ArgoCD reads from the remote repo, not local files. Modifying resources locally while ArgoCD syncs old code from git causes conflicts and prune cascades.

**To make breaking ArgoCD changes safely:**
1. `kubectl scale statefulset argocd-application-controller -n argocd --replicas=0`
2. Make changes, commit, push to git
3. `helm upgrade --install argocd cluster/apps/argocd -n argocd --force-conflicts --wait`
4. `kubectl scale statefulset argocd-application-controller -n argocd --replicas=1`

**After reinstalling Cilium**, restart pods in other namespaces — they get stale network identities causing "operation not permitted" TCP errors: `kubectl rollout restart deployment -n argocd`

**To reinstall cert-manager**, delete the stale ValidatingWebhookConfiguration first, then wait ~15s after install for cainjector to populate CA bundles before retrying.

## Helm Chart Versions

**Never guess chart versions.** Always verify with `helm search repo <chart> --versions | head` or check the upstream GitHub releases page. Use `helm repo update` first if results seem stale.

## Design Documents

Architecture decisions and rationale are in `docs/plans/` (date-prefixed markdown). Read the relevant design doc before modifying a component.

## Critical Gotchas

**Gateway listener ports must be container ports (8000/8443), not service ports (80/443).** Traefik maps entrypoints by container port internally.

**Helm template expressions in ApplicationSet must be escaped** with backtick syntax so Helm passes them through to ArgoCD: `{{ `{{.appName}}` }}`

**config.json uses `chartPath` not `path`** — ArgoCD's git files generator injects its own `path` object that would collide.

**Cilium on Talos requires KubePrism** (`k8sServiceHost: localhost`, `k8sServicePort: 7445`) because the API server isn't network-routable during CNI bootstrap.

**cert-manager Gateway API support** requires file-based `ControllerConfiguration` with `enableGatewayAPI: true` — the feature gate approach is deprecated.

**Helm 4 uses Server-Side Apply by default.** All `helm upgrade` commands need `--force-conflicts` when ArgoCD also manages the same resources via SSA.

**Never use `helm.sh/hook` annotations on resources ArgoCD manages.** `helm template` (used by ArgoCD to compute desired state) skips hook resources, causing ArgoCD to prune them.

**API server defaults on Gateway API resources** (group, kind, weight, path match) must be explicitly specified in templates, otherwise ArgoCD sees permanent drift.

**Longhorn on Talos requires kubelet extra mount** for `/var/lib/longhorn` — the patch in `patches/longhorn.yaml` must be applied and the node rebooted before Longhorn install.

**After reinstalling Longhorn**, existing PVCs may need manual reattachment if the volume data still exists on disk.

**Longhorn v1.11.0 chart moved backup settings** from `defaultSettings.backupTarget` to `defaultBackupStore.backupTarget`. Always run `helm show values` to verify value paths when adding or upgrading charts.

**Longhorn on ArgoCD requires `preUpgradeChecker.jobEnabled: false`** — the pre-upgrade job uses Helm hooks which ArgoCD skips, causing sync failures.

**Talos enforces `baseline` PodSecurity by default on all namespaces.** Components needing privileged access (Longhorn, etc.) require a namespace template with `pod-security.kubernetes.io/enforce: privileged` label.

## Secrets (Not in Git)

| Secret | Namespace | Source |
|---|---|---|
| `cloudflare-api-token` | cert-manager | `task cert-manager` (from vars.yaml) |
| `longhorn-s3-secret` | longhorn-system | `task longhorn-secret` (from vars.yaml) |
| `argocd-repo-key` | argocd | `task argocd` (from local `argocd-repo-key` file) |

Generate the deploy key with `ssh-keygen -t ed25519 -f argocd-repo-key -N ""` and add the public key as a read-only deploy key in GitHub repo settings.
