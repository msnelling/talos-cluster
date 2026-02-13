# db3000 Media Apps Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port all 11 media apps from the old cluster to this cluster using the wrapper Helm chart pattern with a shared local library chart.

**Architecture:** A local library chart (`cluster/lib/media-app/`) provides reusable Deployment/Service/PVC/ConfigMap/HTTPRoute templates. Each media app wraps it as a file dependency. ArgoCD auto-discovers apps via `config.json`. SMB CSI driver provides shared NAS media storage.

**Tech Stack:** Helm, ArgoCD (ApplicationSet, git files generator), Gateway API (HTTPRoute), Cilium (LB-IPAM), Longhorn (PVC), SMB CSI driver

**Design doc:** `docs/plans/2026-02-13-db3000-media-apps-design.md`

**Old cluster context:** `admin@homelab` (namespace `db3000`)

---

### Task 1: Extract secrets from old cluster into vars.yaml

**Files:**
- Modify: `vars.yaml`
- Modify: `vars.yaml.example`

**Step 1: Extract secret values from old cluster**

Run each of these to get the values:

```bash
# SMB credentials
kubectl --context admin@homelab get secret media-smb-creds -n db3000 -o jsonpath='{.data.username}' | base64 -d
kubectl --context admin@homelab get secret media-smb-creds -n db3000 -o jsonpath='{.data.password}' | base64 -d

# VPN secrets
kubectl --context admin@homelab get secret transmission-vpn-secrets -n db3000 -o jsonpath='{.data.VPN_SERVICE_PROVIDER}' | base64 -d
kubectl --context admin@homelab get secret transmission-vpn-secrets -n db3000 -o jsonpath='{.data.VPN_TYPE}' | base64 -d
kubectl --context admin@homelab get secret transmission-vpn-secrets -n db3000 -o jsonpath='{.data.WIREGUARD_PRIVATE_KEY}' | base64 -d
kubectl --context admin@homelab get secret transmission-vpn-secrets -n db3000 -o jsonpath='{.data.WIREGUARD_ADDRESSES}' | base64 -d
kubectl --context admin@homelab get secret transmission-vpn-secrets -n db3000 -o jsonpath='{.data.SERVER_CITIES}' | base64 -d

# Proxy credentials
kubectl --context admin@homelab get secret transmission-proxy-credentials -n db3000 -o jsonpath='{.data.HTTPPROXY_USER}' | base64 -d
kubectl --context admin@homelab get secret transmission-proxy-credentials -n db3000 -o jsonpath='{.data.HTTPPROXY_PASSWORD}' | base64 -d

# Gluetun auth config
kubectl --context admin@homelab get secret gluetun-auth-secrets -n db3000 -o jsonpath='{.data.config\.toml}' | base64 -d
```

**Step 2: Add extracted values to vars.yaml**

Append to the end of `vars.yaml`:

```yaml
# db3000 media apps
smb_username: "<extracted-value>"
smb_password: "<extracted-value>"
vpn_service_provider: "<extracted-value>"
vpn_type: "<extracted-value>"
vpn_wireguard_private_key: "<extracted-value>"
vpn_wireguard_addresses: "<extracted-value>"
vpn_server_cities: "<extracted-value>"
vpn_proxy_user: "<extracted-value>"
vpn_proxy_password: "<extracted-value>"
vpn_auth_config: "<extracted-value>"
```

**Step 3: Add placeholders to vars.yaml.example**

Append to the end of `vars.yaml.example`:

```yaml
# db3000 media apps
smb_username: "your-smb-username"
smb_password: "your-smb-password"
vpn_service_provider: "mullvad"
vpn_type: "wireguard"
vpn_wireguard_private_key: "your-wireguard-private-key"
vpn_wireguard_addresses: "your-wireguard-addresses"
vpn_server_cities: "your-server-cities"
vpn_proxy_user: "your-proxy-user"
vpn_proxy_password: "your-proxy-password"
vpn_auth_config: "your-gluetun-auth-config-toml"
```

**Step 4: Commit**

```bash
git add vars.yaml.example
git commit -m "Add db3000 secret placeholders to vars.yaml.example"
```

Note: `vars.yaml` is git-ignored so only `vars.yaml.example` is committed.

---

### Task 2: Add db3000-secrets task to Taskfile

**Files:**
- Modify: `Taskfile.yaml` (add vars)
- Modify: `taskfiles/components.yaml` (add task)

**Step 1: Add vars to Taskfile.yaml**

Add these vars to the `vars:` block in `Taskfile.yaml`, after the existing `LONGHORN_S3_SECRET_KEY` var:

```yaml
  SMB_USERNAME:
    sh: yq '.smb_username' vars.yaml
  SMB_PASSWORD:
    sh: yq '.smb_password' vars.yaml
  VPN_SERVICE_PROVIDER:
    sh: yq '.vpn_service_provider' vars.yaml
  VPN_TYPE:
    sh: yq '.vpn_type' vars.yaml
  VPN_WIREGUARD_PRIVATE_KEY:
    sh: yq '.vpn_wireguard_private_key' vars.yaml
  VPN_WIREGUARD_ADDRESSES:
    sh: yq '.vpn_wireguard_addresses' vars.yaml
  VPN_SERVER_CITIES:
    sh: yq '.vpn_server_cities' vars.yaml
  VPN_PROXY_USER:
    sh: yq '.vpn_proxy_user' vars.yaml
  VPN_PROXY_PASSWORD:
    sh: yq '.vpn_proxy_password' vars.yaml
  VPN_AUTH_CONFIG:
    sh: yq '.vpn_auth_config' vars.yaml
```

**Step 2: Add db3000-secrets task to taskfiles/components.yaml**

Add after the `longhorn-secret` task:

```yaml
  db3000-secrets:
    desc: Create db3000 namespace and secrets for media apps
    cmds:
      - kubectl create namespace db3000 --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic media-smb-creds
          --namespace db3000
          --from-literal=username={{.SMB_USERNAME}}
          --from-literal=password={{.SMB_PASSWORD}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic transmission-vpn-secrets
          --namespace db3000
          --from-literal=VPN_SERVICE_PROVIDER={{.VPN_SERVICE_PROVIDER}}
          --from-literal=VPN_TYPE={{.VPN_TYPE}}
          --from-literal=WIREGUARD_PRIVATE_KEY={{.VPN_WIREGUARD_PRIVATE_KEY}}
          --from-literal=WIREGUARD_ADDRESSES={{.VPN_WIREGUARD_ADDRESSES}}
          --from-literal=SERVER_CITIES={{.VPN_SERVER_CITIES}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic transmission-proxy-credentials
          --namespace db3000
          --from-literal=HTTPPROXY_USER={{.VPN_PROXY_USER}}
          --from-literal=HTTPPROXY_PASSWORD={{.VPN_PROXY_PASSWORD}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic gluetun-auth-secrets
          --namespace db3000
          --from-literal=config.toml="{{.VPN_AUTH_CONFIG}}"
          --dry-run=client -o yaml | kubectl apply -f -
```

**Step 3: Add db3000-secrets to the setup bootstrap chain**

In `Taskfile.yaml`, in the `setup` task, add after `- task: components:longhorn-secret`:

```yaml
      - task: components:db3000-secrets
```

**Step 4: Verify task is listed**

Run: `task --list`

Expected: `db3000-secrets` appears under `components:`.

**Step 5: Commit**

```bash
git add Taskfile.yaml taskfiles/components.yaml
git commit -m "Add db3000-secrets Taskfile task for media app secrets"
```

---

### Task 3: Expand Cilium IP pool

**Files:**
- Modify: `cluster/apps/cilium/templates/ip-pool.yaml`

**Step 1: Expand the IP pool to include 10.1.1.53**

Replace the current `ip-pool.yaml` content with:

```yaml
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: default-pool
spec:
  blocks:
    - start: 10.1.1.53
      stop: 10.1.1.53
    - start: 10.1.1.60
      stop: 10.1.1.60
```

**Step 2: Verify Helm template renders**

Run: `helm template cilium cluster/apps/cilium --namespace kube-system 2>/dev/null | grep -A10 'CiliumLoadBalancerIPPool'`

Expected: Shows both IP blocks.

**Step 3: Commit**

```bash
git add cluster/apps/cilium/templates/ip-pool.yaml
git commit -m "Add 10.1.1.53 to Cilium IP pool for db3000 LoadBalancer services"
```

---

### Task 4: Create the media-app library chart

**Files:**
- Create: `cluster/lib/media-app/Chart.yaml`
- Create: `cluster/lib/media-app/values.yaml`
- Create: `cluster/lib/media-app/templates/_helpers.tpl`
- Create: `cluster/lib/media-app/templates/deployment.yaml`
- Create: `cluster/lib/media-app/templates/service.yaml`
- Create: `cluster/lib/media-app/templates/configmap.yaml`
- Create: `cluster/lib/media-app/templates/pvc.yaml`
- Create: `cluster/lib/media-app/templates/httproute.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: media-app
description: Shared library chart for db3000 media applications
version: 0.1.0
type: application
```

**Step 2: Create values.yaml (defaults)**

```yaml
name: ""

image:
  repository: ""
  tag: ""
  pullPolicy: IfNotPresent

containerPort: 8080

env: {}

envFromSecret: ""

persistence:
  config:
    enabled: true
    size: 1Gi
    mountPath: /config
    storageClass: ""
  media:
    enabled: false
    claimName: media-share
    mountPath: /media
    subPath: ""

extraVolumes: []
extraVolumeMounts: []

httproute:
  enabled: true
  hostname: db3000.xmple.io
  path: /

service:
  port: 80

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 256Mi

sidecars: []
```

**Step 3: Create _helpers.tpl**

```yaml
{{- define "media-app.name" -}}
{{- .Values.name | default .Chart.Name -}}
{{- end -}}

{{- define "media-app.labels" -}}
app.kubernetes.io/name: {{ include "media-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: db3000
{{- end -}}

{{- define "media-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "media-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

**Step 4: Create deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "media-app.name" . }}
  labels:
    {{- include "media-app.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "media-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "media-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        {{- range .Values.sidecars }}
        - {{- toYaml . | nindent 10 }}
        {{- end }}
        - name: {{ include "media-app.name" . }}
          image: "{{ .Values.image.repository }}{{ if .Values.image.tag }}:{{ .Values.image.tag }}{{ end }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ include "media-app.name" . }}
            {{- if .Values.envFromSecret }}
            - secretRef:
                name: {{ .Values.envFromSecret }}
            {{- end }}
          volumeMounts:
            {{- if .Values.persistence.config.enabled }}
            - name: config
              mountPath: {{ .Values.persistence.config.mountPath }}
            {{- end }}
            {{- if .Values.persistence.media.enabled }}
            - name: media
              mountPath: {{ .Values.persistence.media.mountPath }}
              {{- if .Values.persistence.media.subPath }}
              subPath: {{ .Values.persistence.media.subPath }}
              {{- end }}
            {{- end }}
            {{- with .Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      volumes:
        {{- if .Values.persistence.config.enabled }}
        - name: config
          persistentVolumeClaim:
            claimName: {{ include "media-app.name" . }}-config
        {{- end }}
        {{- if .Values.persistence.media.enabled }}
        - name: media
          persistentVolumeClaim:
            claimName: {{ .Values.persistence.media.claimName }}
        {{- end }}
        {{- with .Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
```

**Step 5: Create service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "media-app.name" . }}
  labels:
    {{- include "media-app.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- include "media-app.selectorLabels" . | nindent 4 }}
```

**Step 6: Create configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "media-app.name" . }}
  labels:
    {{- include "media-app.labels" . | nindent 4 }}
data:
  {{- range $key, $val := .Values.env }}
  {{ $key }}: {{ $val | quote }}
  {{- end }}
```

**Step 7: Create pvc.yaml**

```yaml
{{- if .Values.persistence.config.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "media-app.name" . }}-config
  labels:
    {{- include "media-app.labels" . | nindent 4 }}
spec:
  accessModes:
    - ReadWriteOnce
  {{- if .Values.persistence.config.storageClass }}
  storageClassName: {{ .Values.persistence.config.storageClass }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.config.size }}
{{- end }}
```

**Step 8: Create httproute.yaml**

```yaml
{{- if .Values.httproute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "media-app.name" . }}
  labels:
    {{- include "media-app.labels" . | nindent 4 }}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: traefik
  hostnames:
    - {{ .Values.httproute.hostname }}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: {{ .Values.httproute.path }}
      backendRefs:
        - group: ""
          kind: Service
          name: {{ include "media-app.name" . }}
          port: {{ .Values.service.port }}
          weight: 1
{{- end }}
```

**Step 9: Verify the library chart renders standalone**

Run: `helm template test cluster/lib/media-app --set name=test --set image.repository=nginx --set image.tag=latest --set containerPort=80 --set env.TZ="Europe/London"`

Expected: Renders Deployment, Service, ConfigMap, PVC, HTTPRoute with name `test`.

**Step 10: Commit**

```bash
git add cluster/lib/media-app/
git commit -m "Add media-app library chart for shared db3000 app templates"
```

---

### Task 5: Create media-storage app (SMB CSI + PV/PVC)

**Files:**
- Create: `cluster/apps/media-storage/Chart.yaml`
- Create: `cluster/apps/media-storage/values.yaml`
- Create: `cluster/apps/media-storage/config.json`
- Create: `cluster/apps/media-storage/templates/namespace.yaml`
- Create: `cluster/apps/media-storage/templates/pv.yaml`
- Create: `cluster/apps/media-storage/templates/pvc.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: media-storage
version: 0.1.0
dependencies:
  - name: csi-driver-smb
    version: "1.20.0"
    repository: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
```

**Step 2: Create values.yaml**

```yaml
csi-driver-smb: {}
```

**Step 3: Create config.json**

```json
{"appName": "media-storage", "namespace": "db3000", "chartPath": "cluster/apps/media-storage"}
```

**Step 4: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db3000
```

**Step 5: Create pv.yaml**

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: db3000-media-share
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  mountOptions:
    - dir_mode=0770
    - file_mode=0660
    - uid=568
    - gid=1001
    - forceuid
    - forcegid
    - mfsymlinks
    - nobrl
    - vers=3.0
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: db3000-media-share
    volumeAttributes:
      source: "//10.1.1.30/Media"
    nodeStageSecretRef:
      name: media-smb-creds
      namespace: db3000
```

**Step 6: Create pvc.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media-share
  namespace: db3000
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: db3000-media-share
  resources:
    requests:
      storage: 100Gi
```

**Step 7: Build dependencies and verify**

Run: `helm dependency build cluster/apps/media-storage`

Expected: Downloads `csi-driver-smb` chart.

Run: `helm template media-storage cluster/apps/media-storage --namespace db3000 2>/dev/null | grep -E '^kind:'`

Expected: Lists Namespace, PersistentVolume, PersistentVolumeClaim, and csi-driver-smb resources (DaemonSet, CSIDriver, etc.).

**Step 8: Commit**

```bash
git add cluster/apps/media-storage/
git commit -m "Add media-storage app with SMB CSI driver and shared NAS volume"
```

---

### Task 6: Create radarr app (first app, validates library chart)

This is the first app using the library chart. It validates the pattern before creating the remaining 10 apps.

**Files:**
- Create: `cluster/apps/radarr/Chart.yaml`
- Create: `cluster/apps/radarr/values.yaml`
- Create: `cluster/apps/radarr/config.json`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: radarr
version: 0.1.0
dependencies:
  - name: media-app
    version: "0.1.0"
    repository: "file://../../lib/media-app"
```

**Step 2: Create values.yaml**

```yaml
media-app:
  name: radarr
  image:
    repository: ghcr.io/linuxserver/radarr
    tag: "6.0.4"
  containerPort: 7878
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: true
  httproute:
    hostname: db3000.xmple.io
    path: /radarr
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 512Mi
```

**Step 3: Create config.json**

```json
{"appName": "radarr", "namespace": "db3000", "chartPath": "cluster/apps/radarr"}
```

**Step 4: Build and verify**

Run: `helm dependency build cluster/apps/radarr`

Run: `helm template radarr cluster/apps/radarr --namespace db3000`

Expected: Renders Deployment (image `ghcr.io/linuxserver/radarr:6.0.4`, port 7878), Service (port 80 → http), ConfigMap (TZ, PUID, PGID, UMASK), PVC (1Gi), HTTPRoute (`db3000.xmple.io`, path `/radarr`). All resources have `app.kubernetes.io/name: radarr` labels.

**Step 5: Commit**

```bash
git add cluster/apps/radarr/
git commit -m "Add radarr wrapper chart using media-app library"
```

---

### Task 7: Create sonarr, bazarr, prowlarr, tautulli apps

These four apps follow the identical pattern as radarr — standard LinuxServer.io env vars, config PVC, no extras.

**Files (per app):**
- Create: `cluster/apps/<name>/Chart.yaml`
- Create: `cluster/apps/<name>/values.yaml`
- Create: `cluster/apps/<name>/config.json`

**Step 1: Create sonarr**

`Chart.yaml` — same as radarr but `name: sonarr`.

`values.yaml`:
```yaml
media-app:
  name: sonarr
  image:
    repository: ghcr.io/linuxserver/sonarr
    tag: "4.0.16"
  containerPort: 8989
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: true
  httproute:
    hostname: db3000.xmple.io
    path: /sonarr
  resources:
    requests:
      cpu: 100m
      memory: 600Mi
    limits:
      memory: 600Mi
```

`config.json`:
```json
{"appName": "sonarr", "namespace": "db3000", "chartPath": "cluster/apps/sonarr"}
```

**Step 2: Create bazarr**

`values.yaml`:
```yaml
media-app:
  name: bazarr
  image:
    repository: ghcr.io/linuxserver/bazarr
    tag: "1.5.5"
  containerPort: 6767
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: true
  httproute:
    hostname: db3000.xmple.io
    path: /bazarr
  resources:
    requests:
      cpu: 100m
      memory: 500Mi
    limits:
      memory: 500Mi
```

`config.json`:
```json
{"appName": "bazarr", "namespace": "db3000", "chartPath": "cluster/apps/bazarr"}
```

**Step 3: Create prowlarr**

`values.yaml`:
```yaml
media-app:
  name: prowlarr
  image:
    repository: ghcr.io/linuxserver/prowlarr
    tag: "2.3.0"
  containerPort: 9696
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: false
  httproute:
    hostname: db3000.xmple.io
    path: /prowlarr
  resources:
    requests:
      cpu: 100m
      memory: 384Mi
    limits:
      memory: 384Mi
```

`config.json`:
```json
{"appName": "prowlarr", "namespace": "db3000", "chartPath": "cluster/apps/prowlarr"}
```

**Step 4: Create tautulli**

`values.yaml`:
```yaml
media-app:
  name: tautulli
  image:
    repository: ghcr.io/linuxserver/tautulli
    tag: "2.16.0"
  containerPort: 8181
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: false
  httproute:
    hostname: db3000.xmple.io
    path: /tautulli
  resources:
    requests:
      cpu: 100m
      memory: 600Mi
    limits:
      memory: 600Mi
```

`config.json`:
```json
{"appName": "tautulli", "namespace": "db3000", "chartPath": "cluster/apps/tautulli"}
```

**Step 5: Build and verify each**

```bash
for app in sonarr bazarr prowlarr tautulli; do
  helm dependency build cluster/apps/$app
  echo "=== $app ==="
  helm template $app cluster/apps/$app --namespace db3000 | grep -E '^kind:|containerPort|path:.*/' | head -5
done
```

Expected: Each renders Deployment, Service, ConfigMap, PVC, HTTPRoute with correct ports and paths.

**Step 6: Commit**

```bash
git add cluster/apps/sonarr/ cluster/apps/bazarr/ cluster/apps/prowlarr/ cluster/apps/tautulli/
git commit -m "Add sonarr, bazarr, prowlarr, tautulli wrapper charts"
```

---

### Task 8: Create nzbget app

NzbGet uses a media subPath for downloads.

**Files:**
- Create: `cluster/apps/nzbget/Chart.yaml`
- Create: `cluster/apps/nzbget/values.yaml`
- Create: `cluster/apps/nzbget/config.json`

**Step 1: Create files**

`Chart.yaml` — same structure, `name: nzbget`.

`values.yaml`:
```yaml
media-app:
  name: nzbget
  image:
    repository: ghcr.io/nzbgetcom/nzbget
    tag: "v25.4"
  containerPort: 6789
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: true
      mountPath: /downloads
      subPath: Download/NZBGet
  httproute:
    hostname: db3000.xmple.io
    path: /nzbget
  resources:
    requests:
      cpu: 100m
      memory: 300Mi
    limits:
      memory: 300Mi
```

`config.json`:
```json
{"appName": "nzbget", "namespace": "db3000", "chartPath": "cluster/apps/nzbget"}
```

**Step 2: Build and verify**

Run: `helm dependency build cluster/apps/nzbget && helm template nzbget cluster/apps/nzbget --namespace db3000 | grep -A2 'subPath'`

Expected: Shows `subPath: Download/NZBGet` on the media volume mount.

**Step 3: Commit**

```bash
git add cluster/apps/nzbget/
git commit -m "Add nzbget wrapper chart with download subPath"
```

---

### Task 9: Create jellyseerr app

Jellyseerr serves at the root path (`db3000.xmple.io/`). Uses SQLite (no external DB secret).

**Files:**
- Create: `cluster/apps/jellyseerr/Chart.yaml`
- Create: `cluster/apps/jellyseerr/values.yaml`
- Create: `cluster/apps/jellyseerr/config.json`

**Step 1: Create files**

`Chart.yaml` — same structure, `name: jellyseerr`.

`values.yaml`:
```yaml
media-app:
  name: jellyseerr
  image:
    repository: fallenbagel/jellyseerr
    tag: "2.7.3"
    pullPolicy: Always
  containerPort: 5055
  env:
    TZ: Europe/London
  persistence:
    config:
      size: 5Gi
      mountPath: /app/config
    media:
      enabled: false
  httproute:
    hostname: db3000.xmple.io
    path: /
  resources:
    requests:
      cpu: 100m
      memory: 1Gi
    limits:
      memory: 1Gi
```

`config.json`:
```json
{"appName": "jellyseerr", "namespace": "db3000", "chartPath": "cluster/apps/jellyseerr"}
```

**Step 2: Build and verify**

Run: `helm dependency build cluster/apps/jellyseerr && helm template jellyseerr cluster/apps/jellyseerr --namespace db3000 | grep -E 'mountPath|path:.*/'`

Expected: config mounted at `/app/config`, HTTPRoute path `/`.

**Step 3: Commit**

```bash
git add cluster/apps/jellyseerr/
git commit -m "Add jellyseerr wrapper chart at db3000.xmple.io root path"
```

---

### Task 10: Create audiobookshelf app

Audiobookshelf has custom env vars and mounts config at `/data`.

**Files:**
- Create: `cluster/apps/audiobookshelf/Chart.yaml`
- Create: `cluster/apps/audiobookshelf/values.yaml`
- Create: `cluster/apps/audiobookshelf/config.json`

**Step 1: Create files**

`Chart.yaml` — same structure, `name: audiobookshelf`.

`values.yaml`:
```yaml
media-app:
  name: audiobookshelf
  image:
    repository: ghcr.io/advplyr/audiobookshelf
    tag: "2.32.1"
  containerPort: 80
  env:
    TZ: Europe/London
    CONFIG_PATH: /data/config
    METADATA_PATH: /data/metadata
    BACKUP_PATH: /data/backups
  persistence:
    config:
      size: 1Gi
      mountPath: /data
    media:
      enabled: true
  httproute:
    hostname: db3000.xmple.io
    path: /audiobookshelf
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 512Mi
```

`config.json`:
```json
{"appName": "audiobookshelf", "namespace": "db3000", "chartPath": "cluster/apps/audiobookshelf"}
```

**Step 2: Build and verify**

Run: `helm dependency build cluster/apps/audiobookshelf && helm template audiobookshelf cluster/apps/audiobookshelf --namespace db3000 | grep -E 'mountPath|CONFIG_PATH'`

Expected: config at `/data`, CONFIG_PATH env set.

**Step 3: Commit**

```bash
git add cluster/apps/audiobookshelf/
git commit -m "Add audiobookshelf wrapper chart"
```

---

### Task 11: Create plex app

Plex uses its own hostname (`plex.xmple.io`), needs a LoadBalancer service for direct :32400 access, and has a large config volume.

**Files:**
- Create: `cluster/apps/plex/Chart.yaml`
- Create: `cluster/apps/plex/values.yaml`
- Create: `cluster/apps/plex/config.json`
- Create: `cluster/apps/plex/templates/service-lb.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: plex
version: 0.1.0
dependencies:
  - name: media-app
    version: "0.1.0"
    repository: "file://../../lib/media-app"
```

**Step 2: Create values.yaml**

```yaml
media-app:
  name: plex
  image:
    repository: ghcr.io/linuxserver/plex
    tag: "1.43.0"
  containerPort: 32400
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 50Gi
    media:
      enabled: true
  httproute:
    hostname: plex.xmple.io
    path: /
  service:
    port: 32400
  resources:
    requests:
      cpu: 100m
      memory: 2Gi
    limits:
      memory: 2Gi
```

**Step 3: Create config.json**

```json
{"appName": "plex", "namespace": "db3000", "chartPath": "cluster/apps/plex"}
```

**Step 4: Create service-lb.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-lb
  labels:
    app.kubernetes.io/name: plex
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/part-of: db3000
  annotations:
    lbipam.cilium.io/ips: "10.1.1.53"
    lbipam.cilium.io/sharing-key: db3000
spec:
  type: LoadBalancer
  loadBalancerClass: io.cilium/l2-announcer
  ports:
    - name: pms
      port: 32400
      targetPort: 32400
      protocol: TCP
  selector:
    app.kubernetes.io/name: plex
    app.kubernetes.io/instance: {{ .Release.Name }}
```

**Step 5: Build and verify**

Run: `helm dependency build cluster/apps/plex && helm template plex cluster/apps/plex --namespace db3000 | grep -E '^kind:|32400|plex.xmple.io|10.1.1.53'`

Expected: Two Services (ClusterIP + LoadBalancer), HTTPRoute with `plex.xmple.io`, LB annotation `10.1.1.53`.

**Step 6: Commit**

```bash
git add cluster/apps/plex/
git commit -m "Add plex wrapper chart with LoadBalancer service"
```

---

### Task 12: Create jellyfin app

Jellyfin needs an extra cache PVC and custom env vars.

**Files:**
- Create: `cluster/apps/jellyfin/Chart.yaml`
- Create: `cluster/apps/jellyfin/values.yaml`
- Create: `cluster/apps/jellyfin/config.json`
- Create: `cluster/apps/jellyfin/templates/pvc-cache.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: jellyfin
version: 0.1.0
dependencies:
  - name: media-app
    version: "0.1.0"
    repository: "file://../../lib/media-app"
```

**Step 2: Create values.yaml**

```yaml
media-app:
  name: jellyfin
  image:
    repository: ghcr.io/jellyfin/jellyfin
  containerPort: 8096
  env:
    JELLYFIN_PublishedServerUrl: https://db3000.xmple.io/jellyfin
    JELLYFIN_hostwebclient: "true"
  persistence:
    config:
      size: 50Gi
    media:
      enabled: true
  extraVolumes:
    - name: cache
      persistentVolumeClaim:
        claimName: jellyfin-cache
  extraVolumeMounts:
    - name: cache
      mountPath: /cache
  httproute:
    hostname: db3000.xmple.io
    path: /jellyfin
  resources:
    requests:
      cpu: 100m
      memory: 4Gi
    limits:
      memory: 4Gi
```

**Step 3: Create config.json**

```json
{"appName": "jellyfin", "namespace": "db3000", "chartPath": "cluster/apps/jellyfin"}
```

**Step 4: Create pvc-cache.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-cache
  labels:
    app.kubernetes.io/name: jellyfin
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/part-of: db3000
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
```

**Step 5: Build and verify**

Run: `helm dependency build cluster/apps/jellyfin && helm template jellyfin cluster/apps/jellyfin --namespace db3000 | grep -E 'cache|jellyfin-cache|JELLYFIN_'`

Expected: Shows cache PVC, cache volumeMount at `/cache`, JELLYFIN env vars.

**Step 6: Commit**

```bash
git add cluster/apps/jellyfin/
git commit -m "Add jellyfin wrapper chart with cache volume"
```

---

### Task 13: Create transmission app (VPN sidecar)

Transmission is the most complex app — it has a Gluetun VPN sidecar, multiple secrets, a LoadBalancer service for BitTorrent, and a hostPath volume for `/dev/net/tun`.

**Files:**
- Create: `cluster/apps/transmission/Chart.yaml`
- Create: `cluster/apps/transmission/values.yaml`
- Create: `cluster/apps/transmission/config.json`
- Create: `cluster/apps/transmission/templates/service-lb.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: transmission
version: 0.1.0
dependencies:
  - name: media-app
    version: "0.1.0"
    repository: "file://../../lib/media-app"
```

**Step 2: Create values.yaml**

```yaml
media-app:
  name: transmission
  image:
    repository: ghcr.io/linuxserver/transmission
    tag: "4.1.0"
  containerPort: 9091
  env:
    TZ: Europe/London
    PUID: "568"
    PGID: "1001"
    UMASK: "007"
  persistence:
    config:
      size: 1Gi
    media:
      enabled: true
      mountPath: /downloads
      subPath: Download/Transmission
  httproute:
    hostname: db3000.xmple.io
    path: /transmission
  resources:
    requests:
      cpu: 50m
      memory: 1500Mi
    limits:
      memory: 1500Mi
  sidecars:
    - name: gluetun
      image: docker.io/qmcgaw/gluetun:v3.41.1
      ports:
        - name: proxy
          containerPort: 8888
          protocol: TCP
        - name: control
          containerPort: 8000
          protocol: TCP
      envFrom:
        - configMapRef:
            name: transmission-vpn
        - secretRef:
            name: transmission-vpn-secrets
        - secretRef:
            name: transmission-proxy-credentials
      volumeMounts:
        - name: gluetun-auth
          mountPath: /gluetun/auth/config.toml
          subPath: config.toml
        - name: tun
          mountPath: /dev/net/tun
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
        readOnlyRootFilesystem: false
      resources:
        requests:
          cpu: 100m
      livenessProbe:
        httpGet:
          path: /v1/publicip/ip
          port: 8000
        initialDelaySeconds: 30
        periodSeconds: 30
  extraVolumes:
    - name: gluetun-auth
      secret:
        secretName: gluetun-auth-secrets
    - name: tun
      hostPath:
        path: /dev/net/tun
        type: CharDevice
  extraVolumeMounts: []
```

**Step 3: Create config.json**

```json
{"appName": "transmission", "namespace": "db3000", "chartPath": "cluster/apps/transmission"}
```

**Step 4: Create templates/service-lb.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: transmission-bittorrent
  labels:
    app.kubernetes.io/name: transmission
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/part-of: db3000
  annotations:
    lbipam.cilium.io/ips: "10.1.1.53"
    lbipam.cilium.io/sharing-key: db3000
spec:
  type: LoadBalancer
  loadBalancerClass: io.cilium/l2-announcer
  ports:
    - name: bittorrent-tcp
      port: 51413
      targetPort: 51413
      protocol: TCP
    - name: bittorrent-udp
      port: 51413
      targetPort: 51413
      protocol: UDP
  selector:
    app.kubernetes.io/name: transmission
    app.kubernetes.io/instance: {{ .Release.Name }}
```

**Step 5: Create templates/configmap-vpn.yaml**

This is a separate ConfigMap for Gluetun (non-secret env). Create `cluster/apps/transmission/templates/configmap-vpn.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: transmission-vpn
  labels:
    app.kubernetes.io/name: transmission
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/part-of: db3000
data:
  TZ: Europe/London
  DOT: "off"
  HTTPPROXY: "on"
  HTTPPROXY_LOG: "on"
  HTTP_CONTROL_SERVER_LOG: "off"
  FIREWALL_DEBUG: "on"
  FIREWALL_INPUT_PORTS: "8000,8888,9091,51413"
  HEALTH_TARGET_ADDRESS: "1.1.1.1:443"
  UPDATER_PERIOD: "24h"
  UPDATER_VPN_SERVICE_PROVIDERS: mullvad
  WIREGUARD_MTU: "1420"
```

**Step 6: Build and verify**

Run: `helm dependency build cluster/apps/transmission && helm template transmission cluster/apps/transmission --namespace db3000 | grep -E '^kind:|gluetun|NET_ADMIN|51413|tun'`

Expected: Deployment with 2 containers (gluetun + transmission), LoadBalancer service on 51413, hostPath /dev/net/tun, NET_ADMIN capability.

**Step 7: Commit**

```bash
git add cluster/apps/transmission/
git commit -m "Add transmission wrapper chart with Gluetun VPN sidecar"
```

---

### Task 14: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add db3000 apps to the Secrets table**

Add rows to the secrets table in CLAUDE.md:

```
| `media-smb-creds` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `transmission-vpn-secrets` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `transmission-proxy-credentials` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
| `gluetun-auth-secrets` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
```

**Step 2: Add db3000-secrets to the Components commands**

In the "Individual Component Install/Upgrade" section, add:

```
task components:db3000-secrets  # Create db3000 namespace + media app secrets
```

**Step 3: Add note about the media-app library chart**

Add to the Architecture section, after the Wrapper Helm Chart Pattern:

```markdown
### Local Library Chart (media-app)

Media apps under `cluster/apps/` use a shared library chart at `cluster/lib/media-app/` as a file dependency (`repository: "file://../../lib/media-app"`). This provides reusable Deployment, Service, ConfigMap, PVC, and HTTPRoute templates. Values are nested under `media-app:`.
```

**Step 4: Add note about subpath routing**

Add to Critical Gotchas:

```
**db3000 media apps use subpath routing** at `db3000.xmple.io/<app>`. Plex is the exception (`plex.xmple.io`) because it cannot serve from a subpath.
```

**Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "Document db3000 media apps in CLAUDE.md"
```

---

### Task 15: Full template validation

Verify all 13 apps (media-storage + 11 media apps + transmission) render without errors.

**Step 1: Build all dependencies**

```bash
for app in media-storage radarr sonarr bazarr prowlarr tautulli nzbget jellyseerr audiobookshelf plex jellyfin transmission; do
  echo "=== Building $app ==="
  helm dependency build cluster/apps/$app
done
```

**Step 2: Template all apps**

```bash
for app in media-storage radarr sonarr bazarr prowlarr tautulli nzbget jellyseerr audiobookshelf plex jellyfin transmission; do
  echo "=== Templating $app ==="
  helm template $app cluster/apps/$app --namespace db3000 > /dev/null
  echo "OK"
done
```

Expected: All 12 apps render without errors.

**Step 3: Spot-check key details**

```bash
# Verify all config.json files are valid JSON
for f in cluster/apps/*/config.json; do echo "$f:"; cat "$f" | python3 -m json.tool > /dev/null && echo "  OK"; done

# Verify HTTPRoute paths
for app in radarr sonarr bazarr prowlarr tautulli nzbget jellyseerr audiobookshelf plex jellyfin transmission; do
  path=$(helm template $app cluster/apps/$app --namespace db3000 2>/dev/null | grep -A1 'type: PathPrefix' | grep 'value:' | head -1 | awk '{print $2}')
  echo "$app → $path"
done
```

Expected: Each app shows its correct path (`/radarr`, `/sonarr`, etc.). Plex shows `/`. Jellyseerr shows `/`.

**Step 4: Commit (if any fixes were needed)**

```bash
git add -A && git commit -m "Fix template rendering issues" || echo "No fixes needed"
```
