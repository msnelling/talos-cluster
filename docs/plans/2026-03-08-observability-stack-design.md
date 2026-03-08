# Observability Stack Design

## Context

The cluster has zero observability. A hard kernel lockup on lenovo3 (2026-03-07) went undetected for 17 hours. Pre-crash kernel logs were lost because Talos does not persist logs across reboots. Diagnosing the root cause was impossible — we could only confirm the machine was powered on but unresponsive.

## Goals

1. Capture kernel and system logs off-node in real-time so crash diagnostics survive node failures
2. Alert on node-down and common Kubernetes failure conditions via email
3. Provide Grafana dashboards for cluster health, node metrics, and resource usage
4. Centralize pod and application logs for troubleshooting
5. Keep it simple, with a clear growth path

## Approach

kube-prometheus-stack + Loki + Alloy, deployed as wrapper Helm charts managed by ArgoCD.

## Architecture

```
Talos kernel/service logs ──→ machine.logging (UDP) ──→ Alloy DaemonSet
Container/pod logs ──────────→ /var/log/pods ──────────→ Alloy DaemonSet
                                                              │
                                                              ▼
                                                        Loki (storage)
                                                              │
Prometheus ←── scrapes ── node-exporter (per node)            │
    │                     kube-state-metrics                   │
    │                     kubelet, etcd, etc.                  │
    ▼                                                         │
Alertmanager ──→ email                                        │
    │                                                         │
    ▼                                                         ▼
Grafana ◄──────── dashboards + queries ───────────────────────┘
    │
    ▼
HTTPRoute (grafana.xmple.io)
```

## Components

### kube-prometheus-stack (wrapper chart)

**Chart:** `cluster/apps/kube-prometheus-stack/`
**Upstream:** `prometheus-community/kube-prometheus-stack`
**Namespace:** `monitoring`

Bundles:
- **Prometheus** — metrics collection, 5GB Longhorn PVC, 15-day retention
- **Grafana** — dashboards, 1GB Longhorn PVC for persistence, HTTPRoute at `grafana.xmple.io`
- **Alertmanager** — alert routing, email via SMTP
- **node-exporter** — per-node hardware/OS metrics (DaemonSet)
- **kube-state-metrics** — Kubernetes object metrics (Deployment)

Key configuration:
- Enable all default alert rules (KubeNodeNotReady, NodeFilesystemSpaceFillingUp, TargetDown, etc.)
- Enable etcd scraping on control plane nodes (port 2381)
- Alertmanager SMTP configuration via secret reference
- Grafana admin password via secret

### Loki (wrapper chart)

**Chart:** `cluster/apps/loki/`
**Upstream:** `grafana/loki`
**Namespace:** `monitoring`

Key configuration:
- Single-binary deployment mode (deploymentMode: SingleBinary)
- Filesystem storage backend with 10GB Longhorn PVC
- 7-day log retention
- No object storage (growth path: add S3 later)

### Alloy (wrapper chart)

**Chart:** `cluster/apps/alloy/`
**Upstream:** `grafana/alloy` (replaces deprecated Promtail, EOL 2026-03-02)
**Namespace:** `monitoring`

Key configuration:
- DaemonSet, reads container logs from `/var/log/pods`
- Syslog receiver on UDP port 1514 for Talos `machine.logging` input
- `hostNetwork: true` so Talos can reach it at localhost
- Labels: node, namespace, pod, container
- Ships all logs to Loki endpoint

### Talos machine.logging patch

**File:** `patches/logging.yaml`

Forwards kernel messages and Talos service logs to Alloy's syslog UDP listener on localhost. Applied to all nodes during setup/reconfigure.

```yaml
machine:
  logging:
    destinations:
      - endpoint: "udp://127.0.0.1:1514/"
        format: "json_lines"
```

This ensures kernel-level events (lockups, OOM kills, hardware errors) are captured by Alloy and stored in Loki before a crash occurs.

## Infrastructure Changes

### New app group

`cluster/groups/observability/` — ArgoCD app group containing kube-prometheus-stack, loki, and alloy. Added to the argocd chart's group list.

### Namespace

`monitoring` with `pod-security.kubernetes.io/enforce: privileged` label (required for node-exporter host access).

### Secrets

New secret task `components:monitoring-secrets` in `taskfiles/components.yaml`:
- Alertmanager SMTP credentials (from vars.yaml)
- Grafana admin password (from vars.yaml)

Created using the existing heredoc + `stringData` pattern.

### vars.yaml additions

```yaml
SMTP_HOST: ""
SMTP_PORT: ""
SMTP_USERNAME: ""
SMTP_PASSWORD: ""
SMTP_FROM: ""
ALERT_EMAIL_TO: ""
GRAFANA_ADMIN_PASSWORD: ""
```

## Storage

| Volume | Size | Retention | StorageClass |
|--------|------|-----------|--------------|
| Prometheus data | 5GB | 15 days | longhorn (default, backed up) |
| Grafana data | 1GB | persistent | longhorn (default, backed up) |
| Loki data | 10GB | 7 days | longhorn (default, backed up) |

## Networking

- Grafana exposed at `grafana.xmple.io` via HTTPRoute on the shared wildcard Gateway
- HTTPRoute specifies `sectionName: websecure` for HTTPS binding
- Prometheus and Alertmanager are cluster-internal only (accessible via `kubectl port-forward` if needed)

## Alert Rules (out of the box)

kube-prometheus-stack ships preconfigured rules including:
- `KubeNodeNotReady` — fires when a node is not ready for 15 minutes
- `KubeNodeUnreachable` — fires when a node is unreachable
- `NodeFilesystemSpaceFillingUp` — disk space warnings
- `TargetDown` — scrape target is down
- `KubePodCrashLooping` — pod restart loops
- `KubeMemoryOvercommit` — memory overcommitment
- `etcdNoLeader` — etcd cluster health

These cover the exact failure mode from today's incident.

## Growth Path

All incremental, no rearchitecture needed:
- **S3 backend for Loki** — switch from filesystem to object storage for longer retention
- **Prometheus → Mimir** — if metrics cardinality or retention outgrows Prometheus
- **Alloy → advanced config** — add OpenTelemetry receivers, metrics scraping, or remote-write
- **Add Tempo** — distributed tracing when apps are instrumented
- **Additional exporters** — Longhorn, CNPG, Traefik (many expose /metrics already)
- **PagerDuty/Slack** — additional Alertmanager receivers alongside email

## Bootstrap Considerations

The observability stack is not in the bootstrap chain — it deploys after ArgoCD is running. The Talos `machine.logging` patch must be applied via `task reconfigure` and requires a node reboot to take effect (or applied during initial setup for new clusters).

Secret creation (`task components:monitoring-secrets`) runs after ArgoCD syncs and creates the `monitoring` namespace.
