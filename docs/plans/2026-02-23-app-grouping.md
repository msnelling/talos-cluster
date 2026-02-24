# App Grouping Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `app-group` labels to ArgoCD Applications so apps can be filtered and bulk-managed by group.

**Architecture:** Each app's `config.json` gets a `group` field. The two ApplicationSet templates reference this field as a label on generated Application resources. No new files, no logic changes — just metadata additions.

**Tech Stack:** ArgoCD ApplicationSet, Helm templates, JSON config files

---

### Task 1: Add `group` field to cluster/apps config.json files

**Files:**
- Modify: `cluster/apps/cilium/config.json`
- Modify: `cluster/apps/traefik/config.json`
- Modify: `cluster/apps/cert-manager/config.json`
- Modify: `cluster/apps/longhorn/config.json`
- Modify: `cluster/apps/smb-csi/config.json`
- Modify: `cluster/apps/gitea/config.json`

**Step 1: Update each config.json with its group**

`cluster/apps/cilium/config.json`:
```json
{"appName": "cilium", "namespace": "kube-system", "chartPath": "cluster/apps/cilium", "group": "networking"}
```

`cluster/apps/traefik/config.json`:
```json
{"appName": "traefik", "namespace": "traefik", "chartPath": "cluster/apps/traefik", "group": "networking"}
```

`cluster/apps/cert-manager/config.json`:
```json
{"appName": "cert-manager", "namespace": "cert-manager", "chartPath": "cluster/apps/cert-manager", "group": "platform"}
```

`cluster/apps/longhorn/config.json`:
```json
{"appName": "longhorn", "namespace": "longhorn-system", "chartPath": "cluster/apps/longhorn", "group": "platform"}
```

`cluster/apps/smb-csi/config.json`:
```json
{"appName": "smb-csi", "namespace": "smb-csi", "chartPath": "cluster/apps/smb-csi", "group": "platform"}
```

`cluster/apps/gitea/config.json`:
```json
{"appName": "gitea", "namespace": "gitea", "chartPath": "cluster/apps/gitea", "group": "services"}
```

**Step 2: Commit**

```bash
git add cluster/apps/*/config.json
git commit -m "feat: add group field to cluster app config.json files"
```

---

### Task 2: Add `group` field to cluster/db3000 config.json files

**Files:**
- Modify: `cluster/db3000/audiobookshelf/config.json`
- Modify: `cluster/db3000/bazarr/config.json`
- Modify: `cluster/db3000/jellyfin/config.json`
- Modify: `cluster/db3000/jellyseerr/config.json`
- Modify: `cluster/db3000/media-storage/config.json`
- Modify: `cluster/db3000/nzbget/config.json`
- Modify: `cluster/db3000/plex/config.json`
- Modify: `cluster/db3000/prowlarr/config.json`
- Modify: `cluster/db3000/radarr/config.json`
- Modify: `cluster/db3000/sonarr/config.json`
- Modify: `cluster/db3000/tautulli/config.json`
- Modify: `cluster/db3000/transmission/config.json`

**Step 1: Update each config.json with group "db3000"**

All 12 files get the same `"group": "db3000"` field added. Example for audiobookshelf:

```json
{
  "appName": "audiobookshelf",
  "namespace": "db3000",
  "chartPath": "cluster/db3000/audiobookshelf",
  "group": "db3000"
}
```

Apply the same pattern to all 12 apps.

**Step 2: Commit**

```bash
git add cluster/db3000/*/config.json
git commit -m "feat: add group field to db3000 app config.json files"
```

---

### Task 3: Add app-group label to ApplicationSet templates

**Files:**
- Modify: `cluster/apps/argocd/templates/applicationset.yaml`
- Modify: `cluster/apps/argocd/templates/applicationset-db3000.yaml`

**Step 1: Add label to cluster-apps ApplicationSet**

In `cluster/apps/argocd/templates/applicationset.yaml`, add `labels` under `template.metadata`:

```yaml
  template:
    metadata:
      name: "{{ `{{.appName}}` }}"
      labels:
        app-group: "{{ `{{.group}}` }}"
```

**Step 2: Add label to db3000-apps ApplicationSet**

In `cluster/apps/argocd/templates/applicationset-db3000.yaml`, same change:

```yaml
  template:
    metadata:
      name: "{{ `{{.appName}}` }}"
      labels:
        app-group: "{{ `{{.group}}` }}"
```

**Step 3: Verify templates render correctly**

Run: `helm template argocd cluster/apps/argocd`

Expected: Both ApplicationSet resources should contain `app-group: "{{ `{{.group}}` }}"` in their template metadata labels (the Go template expression passes through Helm to ArgoCD).

**Step 4: Commit**

```bash
git add cluster/apps/argocd/templates/applicationset.yaml cluster/apps/argocd/templates/applicationset-db3000.yaml
git commit -m "feat: add app-group label to ApplicationSet templates"
```

---

### Task 4: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add app grouping documentation**

Add a section under "Working with ArgoCD" documenting group usage:

```markdown
### App Groups

Apps are labeled with `app-group` via config.json's `group` field. Groups: `networking`, `platform`, `services`, `db3000`.

```bash
# Disable auto-sync for maintenance
argocd app list -l app-group=db3000 -o name | xargs -I {} argocd app set {} --sync-policy none

# Re-enable auto-sync
argocd app list -l app-group=db3000 -o name | xargs -I {} argocd app set {} --sync-policy automated --self-heal --auto-prune
```
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add app grouping usage to CLAUDE.md"
```
