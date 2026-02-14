# Intel Quick Sync Video — Design

## Goal

Enable Intel Quick Sync hardware transcoding for Plex and Jellyfin on the Talos Linux cluster.

## Hardware

- Intel i5-4590T (4th gen Haswell), Intel HD Graphics 4600
- Supports H.264 hardware encode/decode, partial H.265 decode
- Device path: `/dev/dri/renderD128`

## Approach

Direct device passthrough (hostPath + securityContext). Chosen over Intel Device Plugin and DRA because the cluster is single-node today and likely to remain small. A node label + nodeSelector handles multi-node scheduling if nodes are added later.

## Changes

### 1. Talos Image — `factory.yaml`

Add `siderolabs/i915-ucode` extension for Intel GPU firmware. Regenerate image via Image Factory, then upgrade node.

### 2. Node Label

Label iGPU nodes after upgrade:

```bash
kubectl label node <node-name> intel.feature.node.kubernetes.io/gpu=true
```

### 3. Media-App Library Chart

Add optional `securityContext` and `nodeSelector` to `cluster/lib/media-app/`:

- **`templates/deployment.yaml`**: Add `nodeSelector` on pod spec and `securityContext` on the main container.
- **`values.yaml`**: Add `securityContext: {}` and `nodeSelector: {}` defaults.

Existing apps are unaffected — both default to empty.

### 4. Plex Values — `cluster/db3000/plex/values.yaml`

- `securityContext.privileged: true`
- `nodeSelector: intel.feature.node.kubernetes.io/gpu: "true"`
- `extraVolumes`: hostPath `/dev/dri`
- `extraVolumeMounts`: mount at `/dev/dri`

### 5. Jellyfin Values — `cluster/db3000/jellyfin/values.yaml`

Same as Plex, merged with existing cache volume/mount.

### 6. App Configuration (Manual)

- **Plex:** Settings > Transcoder > "Use hardware acceleration when available"
- **Jellyfin:** Dashboard > Playback > Hardware acceleration = VAAPI, device `/dev/dri/renderD128`

## Rejected Alternatives

- **Intel GPU Device Plugin**: Adds a DaemonSet for automatic GPU discovery and Kubernetes resource accounting (`gpu.intel.com/i915`). Overkill for a small homelab cluster where manual node labeling is trivial.
- **Dynamic Resource Allocation (DRA)**: Beta feature with significant complexity (NFD, CDI path patches, DRA driver). Not justified for this use case.
