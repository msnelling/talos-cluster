# Observability Stack Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy kube-prometheus-stack + Loki + Alloy for cluster metrics, log aggregation, alerting, and Grafana dashboards, with Talos kernel log forwarding to survive node crashes.

**Architecture:** Three wrapper Helm charts (kube-prometheus-stack, loki, alloy) in a new `observability` app group managed by ArgoCD. Talos `machine.logging` patch forwards kernel/system logs to Alloy DaemonSet, which ships them to Loki. Prometheus scrapes node-exporter, kube-state-metrics, kubelet, and etcd. Alertmanager sends email on critical conditions.

**Tech Stack:** kube-prometheus-stack 82.10.1, Loki 6.53.0, Alloy 1.6.1, Longhorn PVCs, Talos machine.logging

**Chart versions verified on 2026-03-08:**
- `prometheus-community/kube-prometheus-stack` — 82.10.1
- `grafana/loki` — 6.53.0
- `grafana/alloy` — 1.6.1 (replaces deprecated Promtail, EOL 2026-03-02)

---

### Task 1: Talos machine.logging Patch

Create a Talos patch that forwards kernel and service logs to Alloy's syslog receiver on localhost UDP.

**Files:**
- Create: `patches/logging.yaml`
- Modify: `vars.yaml.example` (add comment about observability vars)

**Step 1: Create the logging patch**

Create `patches/logging.yaml`:

```yaml
machine:
  logging:
    destinations:
      - endpoint: "udp://127.0.0.1:1514/"
        format: "json_lines"
```

Note: Talos `machine.logging` cannot use Kubernetes DNS — must use localhost. Alloy runs as a `hostNetwork: true` DaemonSet listening on this port.

**Step 2: Validate patch is valid YAML**

Run: `yq e '.' patches/logging.yaml`
Expected: clean YAML output, no errors

**Step 3: Commit**

```bash
git add patches/logging.yaml
git commit -m "feat(observability): add Talos machine.logging patch for kernel log forwarding"
```

Note: This patch is NOT applied yet. It will be applied via `task reconfigure` after the observability stack is deployed and Alloy is listening. Applying it before Alloy is running is harmless (Talos silently drops logs if destination is unreachable).

---

### Task 2: Alloy Wrapper Chart

Alloy is the log collector DaemonSet. It receives Talos syslog on UDP 1514 and reads pod logs from `/var/log/pods`, then ships everything to Loki.

**Files:**
- Create: `cluster/apps/alloy/Chart.yaml`
- Create: `cluster/apps/alloy/values.yaml`

**Step 1: Create Chart.yaml**

Create `cluster/apps/alloy/Chart.yaml`:

```yaml
apiVersion: v2
name: alloy
version: 0.1.0
dependencies:
  - name: alloy
    version: "1.6.1"
    repository: https://grafana.github.io/helm-charts
```

**Step 2: Create values.yaml**

Create `cluster/apps/alloy/values.yaml`:

```yaml
alloy:
  alloy:
    configMap:
      content: |
        // Receive Talos machine logs via syslog UDP
        loki.source.syslog "talos" {
          listener {
            address = "0.0.0.0:1514"
            protocol = "udp"
            label   = "talos_service"
          }
          forward_to = [loki.write.default.receiver]
        }

        // Discover and collect pod logs
        discovery.kubernetes "pods" {
          role = "pod"
        }

        discovery.relabel "pods" {
          targets = discovery.kubernetes.pods.targets

          rule {
            source_labels = ["__meta_kubernetes_namespace"]
            target_label  = "namespace"
          }
          rule {
            source_labels = ["__meta_kubernetes_pod_name"]
            target_label  = "pod"
          }
          rule {
            source_labels = ["__meta_kubernetes_pod_container_name"]
            target_label  = "container"
          }
          rule {
            source_labels = ["__meta_kubernetes_pod_node_name"]
            target_label  = "node"
          }
        }

        loki.source.kubernetes "pods" {
          targets    = discovery.relabel.pods.output
          forward_to = [loki.write.default.receiver]
        }

        // Ship logs to Loki
        loki.write "default" {
          endpoint {
            url = "http://loki-gateway.monitoring.svc:80/loki/api/v1/push"
          }
        }

  controller:
    type: daemonset
    hostNetwork: true
    dnsPolicy: ClusterFirstWithHostNet

  # Alloy needs access to pod logs on the host
  mounts:
    varlog: true
```

**Step 3: Validate the chart**

Run:
```bash
helm dependency build cluster/apps/alloy && helm lint cluster/apps/alloy
```
Expected: no errors

**Step 4: Template and validate**

Run:
```bash
helm template test cluster/apps/alloy --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: all resources valid

**Step 5: Commit**

```bash
git add cluster/apps/alloy/
git commit -m "feat(observability): add Alloy wrapper chart for log collection"
```

---

### Task 3: Loki Wrapper Chart

Loki stores logs. SingleBinary mode — one pod, filesystem storage on Longhorn.

**Files:**
- Create: `cluster/apps/loki/Chart.yaml`
- Create: `cluster/apps/loki/values.yaml`

**Step 1: Create Chart.yaml**

Create `cluster/apps/loki/Chart.yaml`:

```yaml
apiVersion: v2
name: loki
version: 0.1.0
dependencies:
  - name: loki
    version: "6.53.0"
    repository: https://grafana.github.io/helm-charts
```

**Step 2: Create values.yaml**

Create `cluster/apps/loki/values.yaml`:

```yaml
loki:
  deploymentMode: SingleBinary

  loki:
    auth_enabled: false
    commonConfig:
      replication_factor: 1
    storage:
      type: filesystem
    schemaConfig:
      configs:
        - from: "2024-01-01"
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: loki_index_
            period: 24h
    limits_config:
      retention_period: 168h  # 7 days

  singleBinary:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClass: longhorn

  # Disable components not used in SingleBinary mode
  backend:
    replicas: 0
  read:
    replicas: 0
  write:
    replicas: 0

  # Disable built-in monitoring (we use kube-prometheus-stack)
  monitoring:
    selfMonitoring:
      enabled: false
    lokiCanary:
      enabled: false

  # Disable test pod
  test:
    enabled: false

  # Disable chunksCache and resultsCache for simplicity
  chunksCache:
    enabled: false
  resultsCache:
    enabled: false
```

**Step 3: Validate the chart**

Run:
```bash
helm dependency build cluster/apps/loki && helm lint cluster/apps/loki
```
Expected: no errors

**Step 4: Template and validate**

Run:
```bash
helm template test cluster/apps/loki --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: all resources valid

**Step 5: Commit**

```bash
git add cluster/apps/loki/
git commit -m "feat(observability): add Loki wrapper chart for log aggregation"
```

---

### Task 4: kube-prometheus-stack Wrapper Chart

The main chart: Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics.

**Files:**
- Create: `cluster/apps/kube-prometheus-stack/Chart.yaml`
- Create: `cluster/apps/kube-prometheus-stack/values.yaml`
- Create: `cluster/apps/kube-prometheus-stack/templates/httproute.yaml`
- Create: `cluster/apps/kube-prometheus-stack/templates/namespace.yaml`

**Step 1: Create Chart.yaml**

Create `cluster/apps/kube-prometheus-stack/Chart.yaml`:

```yaml
apiVersion: v2
name: kube-prometheus-stack
version: 0.1.0
dependencies:
  - name: kube-prometheus-stack
    version: "82.10.1"
    repository: https://prometheus-community.github.io/helm-charts
```

**Step 2: Create values.yaml**

Create `cluster/apps/kube-prometheus-stack/values.yaml`:

```yaml
kube-prometheus-stack:
  # All default alert rules are enabled by default — no overrides needed

  alertmanager:
    alertmanagerSpec:
      storage:
        volumeClaimTemplate:
          spec:
            storageClassName: longhorn
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 1Gi
    config:
      route:
        receiver: email
        group_by: ["alertname", "namespace"]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
      receivers:
        - name: email
          email_configs:
            - to: "{{ .Values.alertEmail }}"
              from: "{{ .Values.smtpFrom }}"
              smarthost: "{{ .Values.smtpHost }}:{{ .Values.smtpPort }}"
              auth_username: "{{ .Values.smtpUsername }}"
              auth_password: "{{ .Values.smtpPassword }}"
              require_tls: true

  prometheus:
    prometheusSpec:
      retention: 15d
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: longhorn
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 5Gi

  grafana:
    adminPassword: ""  # Set via secret or values override
    persistence:
      enabled: true
      size: 1Gi
      storageClassName: longhorn
    additionalDataSources:
      - name: Loki
        type: loki
        url: http://loki-gateway.monitoring.svc:80
        access: proxy
        isDefault: false

  # etcd scraping — Talos exposes etcd metrics on port 2381
  kubeEtcd:
    enabled: true
    endpoints:
      - 10.1.1.140
      - 10.1.1.146
      - 10.1.1.203
    service:
      enabled: true
      port: 2381
      targetPort: 2381

  # node-exporter is enabled by default

  # kube-state-metrics is enabled by default

# Wrapper chart values (not nested under dependency)
alertEmail: ""
smtpFrom: ""
smtpHost: ""
smtpPort: "587"
smtpUsername: ""
smtpPassword: ""
```

Note: The alertmanager config uses Go template syntax from the upstream chart. The SMTP values will be passed via `--values /dev/stdin` during the bootstrap install task, similar to the ArgoCD pattern. After ArgoCD takes over, these values would need to be in a secret or managed differently. See Task 6 for the secret approach.

**Step 3: Create namespace template**

Create `cluster/apps/kube-prometheus-stack/templates/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

Required because node-exporter needs host access.

**Step 4: Create HTTPRoute for Grafana**

Create `cluster/apps/kube-prometheus-stack/templates/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - grafana.xmple.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: kube-prometheus-stack-grafana
          port: 80
          weight: 1
```

**Step 5: Validate the chart**

Run:
```bash
helm dependency build cluster/apps/kube-prometheus-stack && helm lint cluster/apps/kube-prometheus-stack
```
Expected: no errors (warnings about CRDs are OK)

**Step 6: Template and validate**

Run:
```bash
helm template test cluster/apps/kube-prometheus-stack --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: most resources valid, some CRD-based resources may show "missing schema" (expected)

**Step 7: Commit**

```bash
git add cluster/apps/kube-prometheus-stack/
git commit -m "feat(observability): add kube-prometheus-stack wrapper chart with Grafana HTTPRoute"
```

---

### Task 5: Observability App Group

Register the three charts as an ArgoCD app group.

**Files:**
- Create: `cluster/groups/observability/Chart.yaml`
- Create: `cluster/groups/observability/values.yaml`
- Create: `cluster/groups/observability/templates/applications.yaml`
- Create: `cluster/groups/observability/templates/namespace.yaml`
- Create: `cluster/apps/argocd/templates/app-group-observability.yaml`

**Step 1: Create the group Chart.yaml**

Create `cluster/groups/observability/Chart.yaml`:

```yaml
apiVersion: v2
name: app-observability
version: 0.1.0
description: Observability app group (kube-prometheus-stack, loki, alloy)
```

**Step 2: Create the group values.yaml**

Create `cluster/groups/observability/values.yaml`:

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

apps:
  - name: kube-prometheus-stack
    namespace: monitoring
    path: cluster/apps/kube-prometheus-stack
  - name: loki
    namespace: monitoring
    path: cluster/apps/loki
  - name: alloy
    namespace: monitoring
    path: cluster/apps/alloy
```

**Step 3: Create the applications template**

Create `cluster/groups/observability/templates/applications.yaml`:

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

**Step 4: Create the ArgoCD group Application**

Create `cluster/apps/argocd/templates/app-group-observability.yaml`:

```yaml
{{- if .Capabilities.APIVersions.Has "argoproj.io/v1alpha1/Application" }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-observability
  namespace: argocd
spec:
  project: cluster
  source:
    repoURL: git@github.com:xmple/talos-cluster.git
    targetRevision: main
    path: cluster/groups/observability
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

**Step 5: Validate the group chart**

Run:
```bash
helm lint cluster/groups/observability
```
Expected: no errors

**Step 6: Validate the argocd chart still renders**

Run:
```bash
helm dependency build cluster/apps/argocd && helm lint cluster/apps/argocd
```
Expected: no errors

**Step 7: Commit**

```bash
git add cluster/groups/observability/ cluster/apps/argocd/templates/app-group-observability.yaml
git commit -m "feat(observability): add observability app group and ArgoCD registration"
```

---

### Task 6: Monitoring Secrets Task

Add a Taskfile task for creating SMTP and Grafana secrets.

**Files:**
- Modify: `taskfiles/components.yaml` — add `monitoring-secrets` task
- Modify: `vars.yaml.example` — add monitoring variables

**Step 1: Add monitoring variables to vars.yaml.example**

Append to `vars.yaml.example`:

```yaml

# Observability
smtp_host: "smtp.example.com"
smtp_port: "587"
smtp_username: "your-smtp-username"
smtp_password: "your-smtp-password"
smtp_from: "alerts@example.com"
alert_email_to: "you@example.com"
grafana_admin_password: "your-grafana-password"
```

**Step 2: Add monitoring-secrets task to components.yaml**

Add this task to `taskfiles/components.yaml`:

```yaml
  monitoring-secrets:
    desc: Create secrets for observability stack (monitoring namespace must exist first)
    deps: [":_require-helm"]
    cmds:
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: alertmanager-smtp
          namespace: monitoring
        type: Opaque
        stringData:
          host: "{{.SMTP_HOST}}"
          port: "{{.SMTP_PORT}}"
          username: "{{.SMTP_USERNAME}}"
          password: "{{.SMTP_PASSWORD}}"
          from: "{{.SMTP_FROM}}"
          to: "{{.ALERT_EMAIL_TO}}"
        EOF
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: grafana-admin
          namespace: monitoring
        type: Opaque
        stringData:
          admin-user: admin
          admin-password: "{{.GRAFANA_ADMIN_PASSWORD}}"
        EOF
```

**Step 3: Add corresponding vars to root Taskfile.yaml**

The root Taskfile loads vars from `vars.yaml`. Add these var mappings if they aren't automatically picked up (check existing patterns — vars.yaml keys are typically referenced with uppercase in taskfiles via `.SMTP_HOST` etc.). Verify the existing var loading pattern in `Taskfile.yaml`.

**Step 4: Commit**

```bash
git add taskfiles/components.yaml vars.yaml.example
git commit -m "feat(observability): add monitoring-secrets task and vars"
```

---

### Task 7: Update Design Doc and CLAUDE.md

Update documentation with the new observability components.

**Files:**
- Modify: `CLAUDE.md` — add monitoring commands, secrets table entries, and observability notes
- Modify: `docs/plans/2026-03-08-observability-stack-design.md` — update Promtail → Alloy

**Step 1: Update CLAUDE.md**

Add to the Components section:

```bash
task components:monitoring-secrets  # Create SMTP and Grafana admin secrets (monitoring namespace)
```

Add to the Secrets table:

```
| `alertmanager-smtp` | monitoring | `task components:monitoring-secrets` (from vars.yaml) |
| `grafana-admin` | monitoring | `task components:monitoring-secrets` (from vars.yaml) |
```

Add to App Groups section:

```
- `app-observability` — kube-prometheus-stack, loki, alloy
```

Add a new section:

```markdown
### Observability

Grafana is exposed at `grafana.xmple.io`. Prometheus, Alertmanager, and Loki are cluster-internal.

Talos kernel and service logs are forwarded via `machine.logging` (patches/logging.yaml) to the Alloy DaemonSet, which ships them to Loki. This ensures pre-crash kernel messages are preserved even if a node hard-locks.

After deploying the observability stack, apply the logging patch: `task reconfigure` (requires node reboot for the patch to take effect).
```

**Step 2: Update design doc**

Update `docs/plans/2026-03-08-observability-stack-design.md` to reflect the change from Promtail to Alloy (Promtail reached EOL on 2026-03-02).

**Step 3: Commit**

```bash
git add CLAUDE.md docs/plans/2026-03-08-observability-stack-design.md
git commit -m "docs: add observability stack to CLAUDE.md and update design doc"
```

---

### Task 8: Validate Full Stack Locally

Final validation before pushing to git for ArgoCD sync.

**Step 1: Build and lint all charts**

Run:
```bash
helm dependency build cluster/apps/kube-prometheus-stack && helm lint cluster/apps/kube-prometheus-stack
helm dependency build cluster/apps/loki && helm lint cluster/apps/loki
helm dependency build cluster/apps/alloy && helm lint cluster/apps/alloy
helm lint cluster/groups/observability
helm dependency build cluster/apps/argocd && helm lint cluster/apps/argocd
```
Expected: all pass

**Step 2: Template and validate**

Run:
```bash
helm template test cluster/apps/kube-prometheus-stack --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
helm template test cluster/apps/loki --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
helm template test cluster/apps/alloy --namespace monitoring | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: all valid (some "missing schema" for CRDs is expected)

**Step 3: Verify ArgoCD chart still renders correctly**

Run:
```bash
helm template test cluster/apps/argocd --namespace argocd | grep -A5 'app-observability'
```
Expected: shows the `app-observability` Application resource

---

### Task 9: Deploy

Push to git and let ArgoCD sync, then create secrets and apply the Talos logging patch.

**Step 1: Push the branch and create PR**

```bash
git push -u origin feat/observability-stack
```

Create PR, review, merge to main.

**Step 2: Wait for ArgoCD to sync**

Watch for the monitoring namespace and pods:
```bash
kubectl get pods -n monitoring -w
```

**Step 3: Create secrets**

Once the monitoring namespace exists:
```bash
task components:monitoring-secrets
```

**Step 4: Verify Grafana is accessible**

Open `https://grafana.xmple.io` and log in with admin credentials.

**Step 5: Verify alert rules are loaded**

In Grafana, navigate to Alerting → Alert Rules. Confirm Kubernetes alert rules are present (KubeNodeNotReady, TargetDown, etc.).

**Step 6: Verify Loki data source**

In Grafana, navigate to Connections → Data Sources. Confirm Loki is listed and test the connection.

**Step 7: Apply Talos logging patch**

```bash
task reconfigure
```

This applies the `patches/logging.yaml` to all nodes. Nodes need a reboot for the patch to take effect:
```bash
task day2:reboot
```

**Step 8: Verify Talos logs are flowing to Loki**

In Grafana, go to Explore → Loki, query `{job="talos"}` or browse labels. Kernel messages should appear from all nodes.

---

## Important Notes

- **kube-prometheus-stack CRDs are large.** The initial ArgoCD sync may take several minutes. If repo-server crashes, it may need the liveness probe timeout increase already configured.
- **Alloy must be running before applying the Talos logging patch** for logs to flow. Applying the patch first is harmless (Talos drops logs silently if destination is unreachable) but wastes the reboot.
- **etcd endpoints are hardcoded** in the kube-prometheus-stack values. If node IPs change, update the values and push to git.
- **The Grafana service name** rendered by kube-prometheus-stack follows the pattern `<release>-grafana`. Since ArgoCD uses the app name as the release name, it will be `kube-prometheus-stack-grafana`. Verify with `kubectl get svc -n monitoring` after deploy and adjust the HTTPRoute `backendRefs` if needed.
- **Alertmanager SMTP config** references wrapper-chart-level values via Go templates. If ArgoCD manages this without the secret values being passed, the alertmanager config will have empty SMTP fields. The monitoring-secrets approach may need refinement — consider using `alertmanagerConfigSecret` to reference a Kubernetes Secret instead of inline config. This should be validated during Task 4.
