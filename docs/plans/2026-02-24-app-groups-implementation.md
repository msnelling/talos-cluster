# App Groups (App-of-Apps) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace ApplicationSets with per-group Helm charts that template Application CRs, enabling bulk sync control from the ArgoCD UI.

**Architecture:** 4 group charts under `cluster/groups/` each render Application CRs for their member apps. The argocd chart creates one parent Application per group with `ignoreDifferences` so UI parameter overrides persist. Existing app charts are unchanged.

**Tech Stack:** Helm charts, ArgoCD Application CRs, YAML

**Design doc:** `docs/plans/2026-02-24-app-groups-app-of-apps-design.md`

---

### Task 1: Create the networking group chart

**Files:**
- Create: `cluster/groups/networking/Chart.yaml`
- Create: `cluster/groups/networking/values.yaml`
- Create: `cluster/groups/networking/templates/applications.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: group-networking
version: 0.1.0
description: Networking app group (cilium, traefik)
```

**Step 2: Create values.yaml**

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

**Step 3: Create templates/applications.yaml**

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
    namespace: {{ .namespace }}
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

**Step 4: Verify template renders**

Run: `helm template group-networking cluster/groups/networking`

Expected: Two Application CRs (cilium and traefik) with correct metadata, labels, syncPolicy, and destinations.

**Step 5: Commit**

```bash
git add cluster/groups/networking/
git commit -m "feat: add networking group chart"
```

---

### Task 2: Create the platform group chart

**Files:**
- Create: `cluster/groups/platform/Chart.yaml`
- Create: `cluster/groups/platform/values.yaml`
- Create: `cluster/groups/platform/templates/applications.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: group-platform
version: 0.1.0
description: Platform app group (cert-manager, longhorn, smb-csi)
```

**Step 2: Create values.yaml**

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

apps:
  - name: cert-manager
    namespace: cert-manager
    path: cluster/apps/cert-manager
  - name: longhorn
    namespace: longhorn-system
    path: cluster/apps/longhorn
  - name: smb-csi
    namespace: smb-csi
    path: cluster/apps/smb-csi
```

**Step 3: Create templates/applications.yaml**

Same template as Task 1 — identical file content.

**Step 4: Verify template renders**

Run: `helm template group-platform cluster/groups/platform`

Expected: Three Application CRs (cert-manager, longhorn, smb-csi) with correct namespaces.

**Step 5: Commit**

```bash
git add cluster/groups/platform/
git commit -m "feat: add platform group chart"
```

---

### Task 3: Create the services group chart

**Files:**
- Create: `cluster/groups/services/Chart.yaml`
- Create: `cluster/groups/services/values.yaml`
- Create: `cluster/groups/services/templates/applications.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: group-services
version: 0.1.0
description: Services app group (gitea)
```

**Step 2: Create values.yaml**

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

apps:
  - name: gitea
    namespace: gitea
    path: cluster/apps/gitea
```

**Step 3: Create templates/applications.yaml**

Same template as Task 1 — identical file content.

**Step 4: Verify template renders**

Run: `helm template group-services cluster/groups/services`

Expected: One Application CR (gitea) with namespace gitea.

**Step 5: Commit**

```bash
git add cluster/groups/services/
git commit -m "feat: add services group chart"
```

---

### Task 4: Create the db3000 group chart

**Files:**
- Create: `cluster/groups/db3000/Chart.yaml`
- Create: `cluster/groups/db3000/values.yaml`
- Create: `cluster/groups/db3000/templates/applications.yaml`
- Create: `cluster/groups/db3000/templates/namespace.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: group-db3000
version: 0.1.0
description: Media app group (db3000)
```

**Step 2: Create values.yaml**

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

namespace:
  name: db3000
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged

apps:
  - name: audiobookshelf
    path: cluster/db3000/audiobookshelf
  - name: bazarr
    path: cluster/db3000/bazarr
  - name: jellyfin
    path: cluster/db3000/jellyfin
  - name: jellyseerr
    path: cluster/db3000/jellyseerr
  - name: media-storage
    path: cluster/db3000/media-storage
  - name: nzbget
    path: cluster/db3000/nzbget
  - name: plex
    path: cluster/db3000/plex
  - name: prowlarr
    path: cluster/db3000/prowlarr
  - name: radarr
    path: cluster/db3000/radarr
  - name: sonarr
    path: cluster/db3000/sonarr
  - name: tautulli
    path: cluster/db3000/tautulli
  - name: transmission
    path: cluster/db3000/transmission
```

**Step 3: Create templates/applications.yaml**

This version differs from the other groups — it uses `namespace.name` as the default namespace:

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
      - ServerSideApply=true
{{- end }}
```

Note: db3000 child apps do NOT have `CreateNamespace=true` — the namespace is managed by the group chart's namespace template instead.

**Step 4: Create templates/namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace.name }}
  labels:
    {{- range $key, $value := .Values.namespace.labels }}
    {{ $key }}: {{ $value }}
    {{- end }}
```

**Step 5: Verify template renders**

Run: `helm template group-db3000 cluster/groups/db3000`

Expected: One Namespace resource (db3000 with privileged labels) + 12 Application CRs all targeting namespace db3000.

**Step 6: Commit**

```bash
git add cluster/groups/db3000/
git commit -m "feat: add db3000 group chart"
```

---

### Task 5: Replace ApplicationSets with group Applications in the argocd chart

**Files:**
- Delete: `cluster/apps/argocd/templates/applicationset.yaml`
- Delete: `cluster/apps/argocd/templates/applicationset-db3000.yaml`
- Create: `cluster/apps/argocd/templates/app-group-networking.yaml`
- Create: `cluster/apps/argocd/templates/app-group-platform.yaml`
- Create: `cluster/apps/argocd/templates/app-group-services.yaml`
- Create: `cluster/apps/argocd/templates/app-group-db3000.yaml`

**Step 1: Create app-group-networking.yaml**

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

**Step 2: Create app-group-platform.yaml**

Same structure, change `name: group-platform` and `path: cluster/groups/platform`.

**Step 3: Create app-group-services.yaml**

Same structure, change `name: group-services` and `path: cluster/groups/services`.

**Step 4: Create app-group-db3000.yaml**

Same structure, change `name: group-db3000` and `path: cluster/groups/db3000`.

**Step 5: Delete the old ApplicationSet files**

```bash
rm cluster/apps/argocd/templates/applicationset.yaml
rm cluster/apps/argocd/templates/applicationset-db3000.yaml
```

**Step 6: Verify argocd chart renders**

Run: `helm template argocd cluster/apps/argocd`

Expected: 4 group Application resources (group-networking, group-platform, group-services, group-db3000) plus the existing argocd self-managed Application and AppProject. No ApplicationSet resources.

**Step 7: Commit**

```bash
git add cluster/apps/argocd/templates/
git commit -m "feat: replace ApplicationSets with group Applications"
```

---

### Task 6: Delete config.json files

**Files:**
- Delete: `cluster/apps/cilium/config.json`
- Delete: `cluster/apps/traefik/config.json`
- Delete: `cluster/apps/cert-manager/config.json`
- Delete: `cluster/apps/longhorn/config.json`
- Delete: `cluster/apps/smb-csi/config.json`
- Delete: `cluster/apps/gitea/config.json`
- Delete: `cluster/db3000/audiobookshelf/config.json`
- Delete: `cluster/db3000/bazarr/config.json`
- Delete: `cluster/db3000/jellyfin/config.json`
- Delete: `cluster/db3000/jellyseerr/config.json`
- Delete: `cluster/db3000/media-storage/config.json`
- Delete: `cluster/db3000/nzbget/config.json`
- Delete: `cluster/db3000/plex/config.json`
- Delete: `cluster/db3000/prowlarr/config.json`
- Delete: `cluster/db3000/radarr/config.json`
- Delete: `cluster/db3000/sonarr/config.json`
- Delete: `cluster/db3000/tautulli/config.json`
- Delete: `cluster/db3000/transmission/config.json`

**Step 1: Remove all config.json files**

```bash
rm cluster/apps/*/config.json cluster/db3000/*/config.json
```

**Step 2: Commit**

```bash
git add -A cluster/apps/*/config.json cluster/db3000/*/config.json
git commit -m "chore: remove config.json files (replaced by group charts)"
```

---

### Task 7: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the Architecture section**

Replace the "Wrapper Helm Chart Pattern" section's reference to `config.json` with the new group chart structure. Remove `config.json` from the file listing. Add `cluster/groups/<name>/` description.

**Step 2: Update the ArgoCD GitOps Flow section**

Replace the ApplicationSet description with the app-of-apps description. Update how apps are discovered (group chart values.yaml instead of config.json).

**Step 3: Update the App Groups subsection**

Replace the CLI-based usage with the UI workflow:

```markdown
### App Groups

Apps are organized into groups via charts under `cluster/groups/` (networking, platform, services, db3000). Each group is an ArgoCD Application that renders child Application CRs.

**Pause a group for maintenance:**
1. Open group app (e.g., `group-db3000`) in ArgoCD UI
2. App Details → Parameters → override `autoSync` = `false`
3. Click Sync

**Resume after maintenance:**
1. Open group app → Parameters → remove `autoSync` override
2. Click Sync

**Adding a new app:** Add entry to the group's `values.yaml`, create the app chart, push to git.
```

**Step 4: Update Critical Gotchas**

Remove the `config.json uses chartPath not path` gotcha. Remove the `Helm template expressions in ApplicationSet must be escaped` gotcha. Both are no longer relevant.

**Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for app-of-apps group structure"
```
