# App Groups via App-of-Apps

## Problem

ArgoCD UI has no bulk action to disable auto-sync across a group of applications. ApplicationSets generate individual Applications, and the ApplicationSet controller reverts manual sync policy changes. Labels help with CLI filtering but don't solve the UI problem.

## Solution

Replace the two ApplicationSets with an app-of-apps pattern. Each group gets a Helm chart that templates Application CRs for its member apps. A single `autoSync` value in the chart controls whether child apps have automated sync. Toggling this value via ArgoCD UI parameter override and syncing the group app bulk-pauses or resumes all child apps.

## Architecture

### Directory Structure

```
cluster/groups/
  networking/       # cilium, traefik
  platform/         # cert-manager, longhorn, smb-csi
  services/         # gitea
  db3000/           # all 12 media apps
```

Each group chart contains:
- `Chart.yaml` — standalone chart, no dependencies
- `values.yaml` — app list, autoSync toggle, repo config
- `templates/applications.yaml` — renders Application CRs from app list
- `templates/namespace.yaml` — (db3000 only) namespace with privileged PodSecurity labels

Existing app charts under `cluster/apps/` and `cluster/db3000/` are unchanged.

### Group Chart Values Schema

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

apps:
  - name: cilium
    namespace: kube-system
    path: cluster/apps/cilium
  - name: traefik
    namespace: traefik
    path: cluster/apps/traefik
```

For db3000, apps share a namespace defined at the top level:

```yaml
namespace:
  name: db3000
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged

apps:
  - name: audiobookshelf
    path: cluster/db3000/audiobookshelf
  # ... all 12 apps
```

### Application CR Template

```yaml
{{- range .Values.apps }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  labels:
    app-group: {{ $.Release.Name }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: {{ $.Values.project }}
  source:
    repoURL: {{ $.Values.repoURL }}
    targetRevision: {{ $.Values.targetRevision }}
    path: {{ .path }}
  destination:
    server: https://kubernetes.default.svc
    namespace: {{ .namespace | default $.Values.namespace.name }}
  syncPolicy:
    {{- if $.Values.autoSync }}
    automated:
      prune: true
      selfHeal: true
    {{- end }}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end }}
```

### ArgoCD Integration

Replace the two ApplicationSets in `cluster/apps/argocd/templates/` with 4 static Application resources (`app-group-networking.yaml`, etc.):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: group-networking
  namespace: argocd
spec:
  project: cluster
  source:
    repoURL: git@github.com:xmple/talos-cluster.git
    targetRevision: main
    path: cluster/groups/networking
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - ServerSideApply=true
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jsonPointers:
        - /spec/syncPolicy
```

`ignoreDifferences` on Application resources prevents ArgoCD from self-healing child app sync policies back to git state after a UI override.

### What Gets Removed

- `cluster/apps/argocd/templates/applicationset.yaml`
- `cluster/apps/argocd/templates/applicationset-db3000.yaml`
- All `config.json` files (18 total) — no longer needed for discovery

## UI Workflow

**Pause a group:**
1. Open group app (e.g., `group-db3000`) in ArgoCD UI
2. App Details → Parameters → override `autoSync` = `false`
3. Click Sync

**Resume a group:**
1. Open group app → Parameters → remove `autoSync` override
2. Click Sync

**Bootstrap:** No special handling. `autoSync` defaults to `true` in git. Fresh install works identically to today with one extra layer of indirection.

**Adding a new app:** Add entry to the group's `values.yaml`, create the app chart, push to git. Group app syncs and creates the new child Application.
