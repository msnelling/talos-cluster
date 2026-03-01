# Minecraft Servers Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy three Minecraft Bedrock servers (mc1, mc2, mc3) into a new `games` ArgoCD group with a shared `minecraft-server` library chart and direct Cilium LB-IPAM networking.

**Architecture:** New library chart at `cluster/lib/minecraft-server/` provides reusable Deployment, Service, ConfigMap, PVC, and PV templates. Three thin wrapper charts under `cluster/games/` reference it. A new `games` ArgoCD group manages the namespace and applications. Cilium IP pool at `10.1.1.52` provides a shared LoadBalancer IP.

**Tech Stack:** Helm (wrapper chart pattern), ArgoCD (app-of-apps), Cilium LB-IPAM, itzg/minecraft-bedrock-server image

---

### Task 1: Create the minecraft-server library chart skeleton

**Files:**
- Create: `cluster/lib/minecraft-server/Chart.yaml`
- Create: `cluster/lib/minecraft-server/values.yaml`
- Create: `cluster/lib/minecraft-server/templates/_helpers.tpl`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: minecraft-server
description: Shared library chart for Minecraft Bedrock servers
version: 0.1.0
type: application
```

**Step 2: Create values.yaml with shared defaults**

```yaml
image:
  repository: docker.io/itzg/minecraft-bedrock-server
  tag: latest
  pullPolicy: Always

port: 19132

env:
  EULA: "true"
  TZ: Europe/London
  VERSION: LATEST
  EMIT_SERVER_TELEMETRY: "true"
  ENABLE_LAN_VISIBILITY: "true"
  PACKAGE_BACKUP_KEEP: "2"
  VIEW_DISTANCE: "32"

persistence:
  size: 2Gi
  existingVolume: ""

service:
  sharingKey: minecraft-lb

resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    memory: 1Gi
```

**Step 3: Create _helpers.tpl**

Follow the media-app pattern but with `part-of: minecraft`.

```yaml
{{- define "minecraft-server.name" -}}
{{- .Values.name | default .Release.Name -}}
{{- end -}}

{{- define "minecraft-server.labels" -}}
app.kubernetes.io/name: {{ include "minecraft-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: minecraft
{{- end -}}

{{- define "minecraft-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "minecraft-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

**Step 4: Commit**

```bash
git add cluster/lib/minecraft-server/
git commit -m "feat(minecraft): add library chart skeleton with defaults"
```

---

### Task 2: Add library chart templates — Deployment and ConfigMap

**Files:**
- Create: `cluster/lib/minecraft-server/templates/deployment.yaml`
- Create: `cluster/lib/minecraft-server/templates/configmap.yaml`

**Step 1: Create deployment.yaml**

Key differences from media-app: `tty: true`, `stdin: true`, liveness probe using `mc-monitor status-bedrock`, port named `bedrock` not `http`, both TCP and UDP.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "minecraft-server.name" . }}
  labels:
    {{- include "minecraft-server.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      {{- include "minecraft-server.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "minecraft-server.labels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ include "minecraft-server.name" . }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          tty: true
          stdin: true
          ports:
            - name: bedrock
              containerPort: {{ .Values.port }}
              protocol: UDP
            - name: bedrock-tcp
              containerPort: {{ .Values.port }}
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ include "minecraft-server.name" . }}
          volumeMounts:
            - name: data
              mountPath: /data
          livenessProbe:
            exec:
              command:
                - mc-monitor
                - status-bedrock
                - --host
                - "127.0.0.1"
                - --port
                - {{ .Values.port | quote }}
            initialDelaySeconds: 120
            periodSeconds: 30
            failureThreshold: 3
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "minecraft-server.name" . }}-data
```

**Step 2: Create configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "minecraft-server.name" . }}
  labels:
    {{- include "minecraft-server.labels" . | nindent 4 }}
data:
  {{- range $key, $val := .Values.env }}
  {{ $key }}: {{ $val | quote }}
  {{- end }}
```

**Step 3: Commit**

```bash
git add cluster/lib/minecraft-server/templates/deployment.yaml cluster/lib/minecraft-server/templates/configmap.yaml
git commit -m "feat(minecraft): add Deployment and ConfigMap templates"
```

---

### Task 3: Add library chart templates — Service, PVC, PV

**Files:**
- Create: `cluster/lib/minecraft-server/templates/service.yaml`
- Create: `cluster/lib/minecraft-server/templates/pvc.yaml`
- Create: `cluster/lib/minecraft-server/templates/pv.yaml`

**Step 1: Create service.yaml**

LoadBalancer service with Cilium L2 announcer, shared IP via sharing key, dual TCP+UDP ports.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "minecraft-server.name" . }}
  labels:
    {{- include "minecraft-server.labels" . | nindent 4 }}
  annotations:
    lbipam.cilium.io/sharing-key: {{ .Values.service.sharingKey }}
spec:
  type: LoadBalancer
  loadBalancerClass: io.cilium/l2-announcer
  ports:
    - name: bedrock
      port: {{ .Values.port }}
      targetPort: bedrock
      protocol: UDP
    - name: bedrock-tcp
      port: {{ .Values.port }}
      targetPort: bedrock-tcp
      protocol: TCP
  selector:
    {{- include "minecraft-server.selectorLabels" . | nindent 4 }}
```

**Step 2: Create pvc.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "minecraft-server.name" . }}-data
  labels:
    {{- include "minecraft-server.labels" . | nindent 4 }}
spec:
  accessModes:
    - ReadWriteOncePod
  {{- if .Values.persistence.existingVolume }}
  storageClassName: longhorn
  volumeName: {{ .Values.persistence.existingVolume }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
```

**Step 3: Create pv.yaml**

Only rendered when binding to a pre-existing Longhorn volume (for data migration).

```yaml
{{- if .Values.persistence.existingVolume }}
apiVersion: v1
kind: PersistentVolume
metadata:
  name: {{ .Values.persistence.existingVolume }}
  labels:
    {{- include "minecraft-server.labels" . | nindent 4 }}
spec:
  capacity:
    storage: {{ .Values.persistence.size }}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOncePod
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: {{ .Values.persistence.existingVolume }}
{{- end }}
```

**Step 4: Validate the library chart**

```bash
helm lint cluster/lib/minecraft-server/
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

**Step 5: Commit**

```bash
git add cluster/lib/minecraft-server/templates/service.yaml cluster/lib/minecraft-server/templates/pvc.yaml cluster/lib/minecraft-server/templates/pv.yaml
git commit -m "feat(minecraft): add Service, PVC, and PV templates"
```

---

### Task 4: Create the three server charts

**Files:**
- Create: `cluster/games/mc1/Chart.yaml`
- Create: `cluster/games/mc1/values.yaml`
- Create: `cluster/games/mc2/Chart.yaml`
- Create: `cluster/games/mc2/values.yaml`
- Create: `cluster/games/mc3/Chart.yaml`
- Create: `cluster/games/mc3/values.yaml`

**Step 1: Create mc1/Chart.yaml**

All three share the same Chart.yaml structure (only name differs):

```yaml
apiVersion: v2
name: mc1
version: 0.1.0
dependencies:
  - name: minecraft-server
    version: "0.1.0"
    repository: "file://../../lib/minecraft-server"
```

Create `mc2/Chart.yaml` and `mc3/Chart.yaml` with `name: mc2` and `name: mc3` respectively.

**Step 2: Create mc1/values.yaml**

```yaml
minecraft-server:
  port: 19132
  env:
    EULA: "true"
    TZ: Europe/London
    VERSION: LATEST
    EMIT_SERVER_TELEMETRY: "true"
    ENABLE_LAN_VISIBILITY: "true"
    PACKAGE_BACKUP_KEEP: "2"
    VIEW_DISTANCE: "32"
    SERVER_NAME: Deddy
    GAMEMODE: creative
    DIFFICULTY: easy
    LEVEL_NAME: My World
    LEVEL_SEED: "7794572526148668328"
    LEVEL_TYPE: DEFAULT
    OPS: "2533274949710273"
    ALLOW_LIST: "true"
    ALLOW_LIST_USERS: "Deddy:2533274949710273,Luna:2535463308445170"
    SERVER_PORT: "19132"
```

**Step 3: Create mc2/values.yaml**

```yaml
minecraft-server:
  port: 19133
  env:
    EULA: "true"
    TZ: Europe/London
    VERSION: LATEST
    EMIT_SERVER_TELEMETRY: "true"
    ENABLE_LAN_VISIBILITY: "true"
    PACKAGE_BACKUP_KEEP: "2"
    VIEW_DISTANCE: "32"
    SERVER_NAME: Deddy
    GAMEMODE: creative
    DIFFICULTY: easy
    LEVEL_NAME: My World 2
    LEVEL_TYPE: DEFAULT
    ALLOW_LIST: "true"
    ALLOW_LIST_USERS: "Deddy:2533274949710273,Luna:2535463308445170"
    SERVER_PORT: "19133"
```

**Step 4: Create mc3/values.yaml**

```yaml
minecraft-server:
  port: 19134
  env:
    EULA: "true"
    TZ: Europe/London
    VERSION: LATEST
    EMIT_SERVER_TELEMETRY: "true"
    ENABLE_LAN_VISIBILITY: "true"
    PACKAGE_BACKUP_KEEP: "2"
    VIEW_DISTANCE: "32"
    SERVER_NAME: Deddy
    GAMEMODE: survival
    DIFFICULTY: easy
    LEVEL_NAME: Survival World
    LEVEL_TYPE: DEFAULT
    OPS: "2533274949710273"
    ALLOW_LIST: "true"
    ALLOW_LIST_USERS: "Deddy:2533274949710273,Luna:2535463308445170"
    SERVER_PORT: "19134"
```

**Step 5: Build dependencies and validate all three**

```bash
helm dependency build cluster/games/mc1/ && helm lint cluster/games/mc1/ && helm template mc1 cluster/games/mc1/ | kubeconform -strict -ignore-missing-schemas -summary
helm dependency build cluster/games/mc2/ && helm lint cluster/games/mc2/ && helm template mc2 cluster/games/mc2/ | kubeconform -strict -ignore-missing-schemas -summary
helm dependency build cluster/games/mc3/ && helm lint cluster/games/mc3/ && helm template mc3 cluster/games/mc3/ | kubeconform -strict -ignore-missing-schemas -summary
```

Expected: All lint and validate successfully.

**Step 6: Commit**

```bash
git add cluster/games/
git commit -m "feat(minecraft): add mc1, mc2, mc3 server charts"
```

---

### Task 5: Add Cilium IP pool for minecraft

**Files:**
- Modify: `cluster/apps/cilium/templates/ip-pool.yaml`

**Step 1: Add minecraft-pool entry**

Append before the `{{- end }}` closing:

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: minecraft-pool
spec:
  blocks:
    - start: 10.1.1.52
      stop: 10.1.1.52
  serviceSelector:
    matchLabels:
      app.kubernetes.io/part-of: minecraft
```

**Step 2: Validate**

```bash
helm dependency build cluster/apps/cilium/ && helm template cilium cluster/apps/cilium/ | kubeconform -strict -ignore-missing-schemas -summary
```

**Step 3: Commit**

```bash
git add cluster/apps/cilium/templates/ip-pool.yaml
git commit -m "feat(minecraft): add Cilium LB IP pool at 10.1.1.52"
```

---

### Task 6: Create the games ArgoCD group

**Files:**
- Create: `cluster/groups/games/Chart.yaml`
- Create: `cluster/groups/games/values.yaml`
- Create: `cluster/groups/games/templates/applications.yaml`
- Create: `cluster/groups/games/templates/namespace.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: app-games
version: 0.1.0
description: Games app group
```

**Step 2: Create values.yaml**

Reference the same repoURL and conventions as db3000 group.

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

namespace:
  name: minecraft

apps:
  - name: mc1
    path: cluster/games/mc1
  - name: mc2
    path: cluster/games/mc2
  - name: mc3
    path: cluster/games/mc3
```

**Step 3: Create templates/applications.yaml**

Reuse the exact same pattern as db3000 group:

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

**Step 4: Create templates/namespace.yaml**

No PodSecurity labels needed — Minecraft runs unprivileged.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace.name }}
```

**Step 5: Validate**

```bash
helm lint cluster/groups/games/ && helm template app-games cluster/groups/games/ | kubeconform -strict -ignore-missing-schemas -summary
```

**Step 6: Commit**

```bash
git add cluster/groups/games/
git commit -m "feat(minecraft): add games ArgoCD group with minecraft namespace"
```

---

### Task 7: Wire the games group into ArgoCD

**Files:**
- Create: `cluster/apps/argocd/templates/app-group-games.yaml`

**Step 1: Create app-group-games.yaml**

Follow the exact pattern from `app-group-db3000.yaml`:

```yaml
{{- if .Capabilities.APIVersions.Has "argoproj.io/v1alpha1/Application" }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-games
  namespace: argocd
spec:
  project: cluster
  source:
    repoURL: git@github.com:xmple/talos-cluster.git
    targetRevision: main
    path: cluster/groups/games
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
{{- end }}
```

**Step 2: Validate the full ArgoCD chart**

```bash
helm dependency build cluster/apps/argocd/ && helm template argocd cluster/apps/argocd/ -n argocd | kubeconform -strict -ignore-missing-schemas -summary
```

**Step 3: Commit**

```bash
git add cluster/apps/argocd/templates/app-group-games.yaml
git commit -m "feat(minecraft): wire games group into ArgoCD app-of-apps"
```

---

### Task 8: Final validation

**Step 1: Run full validation across all changed charts**

```bash
helm dependency build cluster/lib/minecraft-server/
helm dependency build cluster/games/mc1/ && helm lint cluster/games/mc1/ && helm template mc1 cluster/games/mc1/ | kubeconform -strict -ignore-missing-schemas -summary
helm dependency build cluster/games/mc2/ && helm lint cluster/games/mc2/ && helm template mc2 cluster/games/mc2/ | kubeconform -strict -ignore-missing-schemas -summary
helm dependency build cluster/games/mc3/ && helm lint cluster/games/mc3/ && helm template mc3 cluster/games/mc3/ | kubeconform -strict -ignore-missing-schemas -summary
helm lint cluster/groups/games/ && helm template app-games cluster/groups/games/ | kubeconform -strict -ignore-missing-schemas -summary
helm dependency build cluster/apps/cilium/ && helm template cilium cluster/apps/cilium/ | kubeconform -strict -ignore-missing-schemas -summary
```

**Step 2: Inspect rendered output for mc1 to verify correctness**

```bash
helm template mc1 cluster/games/mc1/
```

Verify:
- Deployment has `tty: true`, `stdin: true`, correct ports (UDP+TCP), liveness probe, envFrom ConfigMap
- Service is `type: LoadBalancer` with `loadBalancerClass: io.cilium/l2-announcer` and sharing key annotation
- ConfigMap has all env vars including `SERVER_PORT: "19132"`
- PVC is 2Gi with no storageClass (dynamic provisioning)
- No PV rendered (no existingVolume set)
- All labels include `app.kubernetes.io/part-of: minecraft`
