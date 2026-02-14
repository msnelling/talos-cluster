# Intel Quick Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable Intel Quick Sync hardware transcoding for Plex and Jellyfin.

**Architecture:** Add `i915-ucode` Talos extension for GPU firmware, extend the media-app library chart with optional `securityContext` and `nodeSelector`, then configure Plex and Jellyfin to mount `/dev/dri` for iGPU access. See `docs/plans/2026-02-14-quick-sync-design.md` for full design rationale.

**Tech Stack:** Talos Linux, Helm, ArgoCD, Intel HD Graphics 4600 (Haswell)

---

### Task 1: Add i915-ucode extension to Talos image config

**Files:**
- Modify: `factory.yaml`

**Step 1: Add the extension**

Add `siderolabs/i915-ucode` to the extensions list in `factory.yaml`:

```yaml
customization:
    systemExtensions:
        officialExtensions:
            - siderolabs/intel-ucode
            - siderolabs/i915-ucode
            - siderolabs/iscsi-tools
            - siderolabs/tailscale
            - siderolabs/util-linux-tools
```

**Step 2: Commit**

```bash
git add factory.yaml
git commit -m "Add i915-ucode extension for Intel Quick Sync GPU firmware"
```

> **Note:** The actual Talos image rebuild and node upgrade happen out-of-band after all code changes are committed and pushed. Run `task setup:download` to get the new image, then `task day2:upgrade-talos` to apply it.

---

### Task 2: Add securityContext and nodeSelector to media-app library chart

**Files:**
- Modify: `cluster/lib/media-app/values.yaml`
- Modify: `cluster/lib/media-app/templates/deployment.yaml`

**Step 1: Add defaults to values.yaml**

Add to the end of `cluster/lib/media-app/values.yaml`:

```yaml
securityContext: {}
nodeSelector: {}
```

**Step 2: Add nodeSelector to deployment template**

In `cluster/lib/media-app/templates/deployment.yaml`, add `nodeSelector` block inside `spec.template.spec`, before the `containers:` line:

```yaml
    spec:
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
```

**Step 3: Add securityContext to main container**

In the same file, add `securityContext` block on the main container, after the `imagePullPolicy` line:

```yaml
        - name: {{ include "media-app.name" . }}
          image: "{{ .Values.image.repository }}{{ if .Values.image.tag }}:{{ .Values.image.tag }}{{ end }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
```

**Step 4: Verify templates render correctly for an unmodified app**

Run helm template on an app that does NOT use GPU (e.g., radarr) to confirm no regressions — the output should be identical to before since both values default to `{}`:

```bash
helm dependency build cluster/db3000/radarr && helm template radarr cluster/db3000/radarr
```

Expected: Deployment renders without `nodeSelector` or `securityContext` blocks (they are omitted when empty).

**Step 5: Commit**

```bash
git add cluster/lib/media-app/values.yaml cluster/lib/media-app/templates/deployment.yaml
git commit -m "Add optional securityContext and nodeSelector to media-app library chart"
```

---

### Task 3: Configure Plex for Quick Sync

**Files:**
- Modify: `cluster/db3000/plex/values.yaml`

**Step 1: Add GPU config to Plex values**

Add the following keys to the `media-app:` section in `cluster/db3000/plex/values.yaml`:

```yaml
media-app:
  # ... existing values stay unchanged ...
  securityContext:
    privileged: true
  nodeSelector:
    intel.feature.node.kubernetes.io/gpu: "true"
  extraVolumes:
    - name: dri
      hostPath:
        path: /dev/dri
        type: Directory
  extraVolumeMounts:
    - name: dri
      mountPath: /dev/dri
```

**Step 2: Verify rendered template**

```bash
helm dependency build cluster/db3000/plex && helm template plex cluster/db3000/plex
```

Expected: Deployment includes `nodeSelector` with the GPU label, `securityContext.privileged: true`, and a `dri` hostPath volume mounted at `/dev/dri`.

**Step 3: Commit**

```bash
git add cluster/db3000/plex/values.yaml
git commit -m "Enable Intel Quick Sync GPU passthrough for Plex"
```

---

### Task 4: Configure Jellyfin for Quick Sync

**Files:**
- Modify: `cluster/db3000/jellyfin/values.yaml`

**Step 1: Add GPU config to Jellyfin values**

Replace the existing `extraVolumes` and `extraVolumeMounts` and add the new keys in `cluster/db3000/jellyfin/values.yaml`:

```yaml
media-app:
  # ... existing values stay unchanged ...
  securityContext:
    privileged: true
  nodeSelector:
    intel.feature.node.kubernetes.io/gpu: "true"
  extraVolumes:
    - name: cache
      persistentVolumeClaim:
        claimName: jellyfin-cache
    - name: dri
      hostPath:
        path: /dev/dri
        type: Directory
  extraVolumeMounts:
    - name: cache
      mountPath: /cache
    - name: dri
      mountPath: /dev/dri
```

**Step 2: Verify rendered template**

```bash
helm dependency build cluster/db3000/jellyfin && helm template jellyfin cluster/db3000/jellyfin
```

Expected: Deployment includes `nodeSelector`, `securityContext.privileged: true`, both the `cache` PVC and `dri` hostPath volumes, and both volume mounts.

**Step 3: Commit**

```bash
git add cluster/db3000/jellyfin/values.yaml
git commit -m "Enable Intel Quick Sync GPU passthrough for Jellyfin"
```

---

### Task 5: Post-deploy manual steps (reference only)

These steps happen after pushing to git and letting ArgoCD sync, and after the Talos image upgrade:

1. **Rebuild Talos image:** `task setup:download` (with updated factory.yaml schematic)
2. **Upgrade node:** `task day2:upgrade-talos` (node reboots)
3. **Label node:** `kubectl label node <node-name> intel.feature.node.kubernetes.io/gpu=true`
4. **Verify device:** `talosctl read /proc/bus/pci/devices | grep -i vga` or check that `/dev/dri/renderD128` exists
5. **Plex:** Settings > Transcoder > enable "Use hardware acceleration when available"
6. **Jellyfin:** Dashboard > Playback > Hardware acceleration = "Video Acceleration API (VAAPI)", device = `/dev/dri/renderD128`
