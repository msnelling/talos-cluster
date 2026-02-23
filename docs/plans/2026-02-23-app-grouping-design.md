# App Grouping via ArgoCD Labels

## Problem

No way to act on groups of applications at once (e.g., disable auto-sync on all db3000 apps during maintenance). Apps are individually managed, requiring per-app toggling.

## Solution

Add a `group` field to each app's `config.json`. The ApplicationSet templates propagate this as an `app-group` label on each ArgoCD Application resource. This enables filtering and bulk operations via the ArgoCD UI and CLI.

## Changes

### 1. config.json Schema

Add `"group"` field to every config.json:

```json
{"appName": "radarr", "namespace": "db3000", "chartPath": "cluster/db3000/radarr", "group": "db3000"}
```

### 2. Group Assignments

| Group | Apps |
|-------|------|
| `networking` | cilium, traefik |
| `platform` | cert-manager, longhorn, smb-csi |
| `services` | gitea |
| `db3000` | audiobookshelf, bazarr, jellyfin, jellyseerr, media-storage, nzbget, plex, prowlarr, radarr, sonarr, tautulli, transmission |

### 3. ApplicationSet Template Changes

Both `applicationset.yaml` and `applicationset-db3000.yaml` add the label:

```yaml
template:
  metadata:
    name: "{{ `{{.appName}}` }}"
    labels:
      app-group: "{{ `{{.group}}` }}"
```

### 4. Usage

```bash
# List apps in a group
argocd app list -l app-group=db3000

# Disable auto-sync for maintenance
argocd app list -l app-group=db3000 -o name | xargs -I {} argocd app set {} --sync-policy none

# Re-enable auto-sync
argocd app list -l app-group=db3000 -o name | xargs -I {} argocd app set {} --sync-policy automated --self-heal --auto-prune
```

The ArgoCD UI also supports label-based filtering.

## Notes

- Labels are metadata-only; no behavioral change until explicitly toggled.
- When ArgoCD re-syncs the ApplicationSet after a git push, it will restore auto-sync on any apps that were manually paused. This is expected — maintenance windows are temporary, and the git state is the source of truth.
- New apps just need to include `"group"` in their config.json to be grouped automatically.
