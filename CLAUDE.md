# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Talos Linux Kubernetes cluster with full GitOps management via ArgoCD. Supports single-node and multi-node topologies. All cluster components are deployed as **wrapper Helm charts** and managed declaratively through git.

**Stack:** Talos v1.12.3, Kubernetes v1.35.0, Cilium CNI, Traefik (Gateway API), cert-manager, Longhorn, ArgoCD

## Commands

### Bootstrap
```bash
task setup    # Full cluster bootstrap for all nodes defined in vars.yaml
```

### Individual Component Install/Upgrade
```bash
task components:cilium           # Install/upgrade Cilium CNI (kube-system)
task components:traefik          # Install/upgrade Traefik (traefik namespace)
task components:cert-manager     # Install/upgrade cert-manager (cert-manager namespace)
task components:longhorn-secret  # Create Longhorn namespace + S3 backup secret
task components:argocd           # Install/upgrade ArgoCD (argocd namespace)
task components:db3000-secrets  # Create db3000 namespace + media app secrets
task components:renovate-secret  # Create Renovate GitHub App secret
```

Each Helm component task runs: `helm repo add` → `helm dependency build` → `helm upgrade --install` with `--force-conflicts` (required for Helm 4 SSA compatibility with ArgoCD).

### Secret Creation Convention

Secrets in `taskfiles/components.yaml` use heredoc + `stringData` piped to `kubectl apply -f -` (not `--from-literal` CLI args) so values never appear in the process table. Helm secret values use `--values /dev/stdin` with a heredoc instead of `--set`. Follow this pattern for any new secrets.

### Day-2 Operations
```bash
task day2:upgrade-talos   # Rolling Talos upgrade across all nodes
task day2:upgrade-k8s     # Upgrade Kubernetes (cluster-wide)
task day2:reboot          # Rolling reboot across all nodes
task day2:reset           # Wipe all nodes (DESTRUCTIVE, prompts for confirmation)
task day2:join-node -- <name>  # Join a new node to the existing cluster
task reconfigure          # Re-patch and apply Talos config changes to all nodes
```

After ArgoCD is running, component upgrades go through git: bump the version in `Chart.yaml`, push to `main`, ArgoCD auto-syncs.

### Utilities
```bash
task utility:status       # Cluster health check (Talos + kubectl + Cilium)
task utility:dashboard    # Interactive Talos dashboard
task utility:disks        # List disks on all nodes (useful before first install)
task utility:links        # List network interfaces on all nodes
task setup:download       # Download Talos secure-boot ISO from Image Factory
task setup:kubeconfig     # Retrieve and merge kubeconfig
```

### Taskfile Structure

Tasks are split into domain-grouped files under `taskfiles/` with namespaced includes:
- `taskfiles/setup.yaml` -- cluster provisioning (download, generate, patch, apply, bootstrap, kubeconfig)
- `taskfiles/components.yaml` -- Helm component installs and secrets (cilium, traefik, cert-manager, longhorn-secret, argocd)
- `taskfiles/day2.yaml` -- ongoing operations (upgrade-talos, upgrade-k8s, reboot, reset)
- `taskfiles/utility.yaml` -- diagnostics (status, dashboard, disks, links)

Root `Taskfile.yaml` holds global vars, shared precondition helpers (`_require-nodes`, `_require-helm`), and top-level orchestration tasks (`setup`, `reconfigure`).

### Bootstrap vs ArgoCD-Managed Components

Only components that must exist before ArgoCD belong in the Taskfile bootstrap chain (Cilium, Traefik, cert-manager). ArgoCD owns namespace creation for all other components via `CreateNamespace=true`. Secret tasks (e.g., `longhorn-secret`, `gitea-secrets`) run after ArgoCD has synced and created the target namespaces. The bootstrap sequence waits for ArgoCD to create namespaces before populating secrets. ArgoCD handles CRD-before-CR ordering natively, which avoids Helm's inability to install custom resources alongside the CRDs that define them.

## Architecture

### Wrapper Helm Chart Pattern

Every component under `cluster/apps/<name>/` is a self-contained Helm chart wrapping an upstream dependency:

```
cluster/apps/<name>/
  Chart.yaml        # Declares upstream chart as dependency with pinned version
  values.yaml       # Config nested under dependency name (e.g., cilium:, traefik:, argo-cd:)
  templates/        # Optional raw K8s manifests deployed alongside the dependency
```

**Values nesting is mandatory** — Helm scopes values to the dependency alias. A Traefik value goes under `traefik:`, Cilium under `cilium:`, ArgoCD under `argo-cd:`.

### Local Library Chart (media-app)

Media apps under `cluster/apps/` use a shared library chart at `cluster/lib/media-app/` as a file dependency (`repository: "file://../../lib/media-app"`). This provides reusable Deployment, Service, ConfigMap, PVC, and HTTPRoute templates. Values are nested under `media-app:`.

### ArgoCD GitOps Flow

**App-of-apps pattern** organizes applications into groups. Group charts under `cluster/groups/<group>/` template Application CRs for their member apps. The argocd chart creates one parent Application per group (`app-networking`, `app-platform`, `app-services`, `app-db3000`).

```
cluster/groups/<group>/
  Chart.yaml              # Standalone chart, no dependencies
  values.yaml             # App list, autoSync toggle, repo config
  templates/
    applications.yaml     # Renders Application CRs from app list
    namespace.yaml        # (db3000 only) Namespace with PodSecurity labels
```

**Adding a new app:** Add an entry to the group's `values.yaml` and create the app chart. Push to git.

**ArgoCD self-management** is handled separately via a dedicated `Application` resource with `prune: false` to prevent ArgoCD from ever deleting its own resources.

**Sync policy:** All apps use auto-sync + self-heal + ServerSideApply. Non-ArgoCD apps also have prune enabled.

### Networking Stack

```
Client → DNS (*.xmple.io → 10.1.1.60) → Cilium LB-IPAM (L2 announcement)
  → Traefik Service (80/443) → Traefik container (8000/8443)
  → HTTPRoute matching → Backend Service
```

- **Cilium** provides LoadBalancer IPs via LB-IPAM + L2 announcements (no MetalLB needed)
- **Traefik** is the Gateway API controller; shared wildcard Gateway in traefik namespace
- **HTTPRoutes must specify `sectionName: websecure`** in parentRefs to bind only to the HTTPS listener. HTTP-to-HTTPS redirect is handled by a dedicated HTTPRoute on the `web` listener using a `RequestRedirect` filter (standard Gateway API pattern).
- **cert-manager** watches Gateway annotations and auto-creates wildcard certificates via Cloudflare DNS-01

### Configuration

`vars.yaml` (git-ignored) holds cluster config: node list (name, IP, role, disk, interface), Talos/K8s versions, optional control plane VIP, and secrets. See `vars.yaml.example` for structure. Nodes default to `controlplane` role (mixed mode — runs both control plane and workloads). Set `role: worker` for dedicated worker nodes. Set `schedulable: false` on a control plane node to apply a `NoSchedule` taint, preventing workload pods from being scheduled on it. Defaults to `true`. Set `control_plane_vip` when using multiple control plane nodes. Helm chart versions are pinned in each app's `Chart.yaml`, not in `vars.yaml`.

`factory.yaml` defines the custom Talos image with extensions (Tailscale, Intel microcode, iSCSI).

## Working with ArgoCD

**Always push changes to git before expecting ArgoCD to sync them.** ArgoCD reads from the remote repo, not local files. Modifying resources locally while ArgoCD syncs old code from git causes conflicts and prune cascades.

**To diagnose OutOfSync resources:** `kubectl get application -n argocd -o json` and parse for resources where `status != "Synced"`. Then compare the live object (`kubectl get <kind> <name> -n <ns> -o yaml`) against the rendered template (`helm template`) to identify API server defaults causing drift.

**To make breaking ArgoCD changes safely:**
1. `kubectl scale statefulset argocd-application-controller -n argocd --replicas=0`
2. Delete any old resources from the cluster that will be replaced (e.g., ApplicationSets, Applications)
3. Make changes, commit, push to git
4. `helm upgrade --install argocd cluster/apps/argocd -n argocd --force-conflicts --wait`
5. `kubectl scale statefulset argocd-application-controller -n argocd --replicas=1`

**Replacing resource generators (ApplicationSets, app-of-apps charts):** Always delete the old generator from the cluster before removing its discovery sources from git. If you remove discovery files (e.g., config.json) while the old generator is still running, it will interpret "zero sources" as "delete all generated resources" and cascade-delete everything it manages — including CNI, ingress, and storage.

**After reinstalling Cilium**, restart pods in other namespaces — they get stale network identities causing "operation not permitted" TCP errors: `kubectl rollout restart deployment -n argocd`

**To reinstall cert-manager**, delete both stale webhook configurations first (`kubectl delete validatingwebhookconfiguration cert-manager-webhook && kubectl delete mutatingwebhookconfiguration cert-manager-webhook`), then wait ~15s after install for cainjector to populate CA bundles before retrying.

### App Groups

Apps are organized into groups via charts under `cluster/groups/` (networking, platform, services, db3000). Each group is an ArgoCD Application that renders child Application CRs.

**Pause a group for maintenance:**
1. Open group app (e.g., `app-db3000`) in ArgoCD UI
2. App Details → Parameters → override `autoSync` = `false`
3. Click Sync

**Resume after maintenance:**
1. Open group app → Parameters → remove `autoSync` override
2. Click Sync

## Helm Chart Versions

**Never guess chart versions.** Always verify with `helm search repo <chart> --versions | head` or check the upstream GitHub releases page. Use `helm repo update` first if results seem stale.

## Design Documents

Architecture decisions and rationale are in `docs/plans/` (date-prefixed markdown). Read the relevant design doc before modifying a component.

## Critical Gotchas

**Never commit directly to `main`.** Always create a feature branch first (`git checkout -b feat/<name>` or `fix/<name>`), do the work there, then open a PR. This includes design docs, plans, and any other changes.

**Gateway listener ports must be container ports (8000/8443), not service ports (80/443).** Traefik maps entrypoints by container port internally.

**Cilium on Talos requires KubePrism** (`k8sServiceHost: localhost`, `k8sServicePort: 7445`) because the API server isn't network-routable during CNI bootstrap.

**cert-manager Gateway API support** requires file-based `ControllerConfiguration` with `enableGatewayAPI: true` — the feature gate approach is deprecated.

**Helm 4 uses Server-Side Apply by default.** All `helm upgrade` commands need `--force-conflicts` when ArgoCD also manages the same resources via SSA.

**Never use `helm.sh/hook` annotations on resources ArgoCD manages.** `helm template` (used by ArgoCD to compute desired state) skips hook resources, causing ArgoCD to prune them.

**API server defaults on Gateway API resources** (group, kind, weight, path match) must be explicitly specified in templates, otherwise ArgoCD sees permanent drift.

**Longhorn on Talos requires kubelet extra mount** for `/var/lib/longhorn` — the patch in `patches/longhorn.yaml` must be applied and the node rebooted before Longhorn install.

**After reinstalling Longhorn**, existing PVCs may need manual reattachment if the volume data still exists on disk.

**Longhorn v1.11.0 chart moved backup settings** from `defaultSettings.backupTarget` to `defaultBackupStore.backupTarget`. Always run `helm show values` to verify value paths when adding or upgrading charts.

**Longhorn on ArgoCD requires `preUpgradeChecker.jobEnabled: false`** — the pre-upgrade job uses Helm hooks which ArgoCD skips, causing sync failures.

**Longhorn's pre-delete hook (`longhorn-uninstall`) is destructive.** If a Longhorn Application is deleted with `resources-finalizer` and `pre-delete-finalizer`, ArgoCD will repeatedly run the uninstall job. Fix by removing finalizers from the Application (`kubectl patch application longhorn -n argocd --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`), then deleting the uninstall job.

**Talos enforces `baseline` PodSecurity by default on all namespaces.** Components needing privileged access (Longhorn, etc.) require a namespace template with `pod-security.kubernetes.io/enforce: privileged` label.

**db3000 media apps use subpath routing** at `db3000.xmple.io/<app>`. Plex is the exception (`plex.xmple.io`) because it cannot serve from a subpath.

**Gitea chart templates `targetPort` from `gitea.config.server.HTTP_PORT`**, not from `service.http.targetPort`. This value must be explicitly set in the wrapper values or the Service renders with an empty targetPort that fails schema validation.

**Always validate charts locally before pushing:** `helm dependency build <chart> && helm lint <chart> && helm template test <chart> | kubeconform -strict -ignore-missing-schemas -summary`

**Traefik chart enforces a values schema.** Always run `helm show values traefik/traefik --version <ver>` to verify value paths before adding new configuration. `helm lint` catches schema violations locally.

**Multi-node control plane requires `control_plane_vip`** in `vars.yaml`. This enables Talos's built-in Virtual IP for the Kubernetes API endpoint. Single control plane nodes don't need it — the endpoint falls back to the node's IP.

## Secrets (Not in Git)

| Secret | Namespace | Source |
|---|---|---|
| `cloudflare-api-token` | cert-manager | `task components:cert-manager` (from vars.yaml) |
| `longhorn-s3-secret` | longhorn-system | `task components:longhorn-secret` (from vars.yaml) |
| `argocd-repo-key` | argocd | `task components:argocd` (from local `argocd-repo-key` file) |
| `argocd-secret` (dex.github.clientSecret) | argocd | `task components:argocd` (from vars.yaml) |
| `media-smb-creds` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `transmission-vpn-secrets` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `transmission-proxy-credentials` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `gluetun-auth-secrets` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `gitea-admin-secret` | gitea | `task components:gitea-secrets` (from vars.yaml) |
| `gitea-config-secrets` | gitea | `task components:gitea-secrets` (from vars.yaml) |
| `renovate-token` | renovate | `task components:renovate-secret` (from vars.yaml + `renovate-app-key.pem` file) |

Generate the deploy key with `ssh-keygen -t ed25519 -f argocd-repo-key -N ""` and add the public key as a read-only deploy key in GitHub repo settings.
