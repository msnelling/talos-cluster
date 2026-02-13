# Longhorn Storage Design

## Goal

Add Longhorn as the cluster's persistent storage provider with automated daily backups to S3 (TrueNAS/Minio). All configuration is declarative and managed through git via the existing wrapper Helm chart pattern.

## Context

- Single-node Talos v1.12.3 cluster, Kubernetes v1.35.0
- No existing storage provider — all workloads currently lack persistent storage
- Talos image already includes `iscsi-tools` and `util-linux-tools` extensions (required by Longhorn)
- Minio instance running on TrueNAS with S3-compatible endpoint available
- Existing GitOps flow: wrapper Helm charts in `cluster/apps/`, auto-discovered by ArgoCD ApplicationSet via `config.json`

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Storage provider | Longhorn v1.11.0 | Purpose-built for Kubernetes, native S3 backup, good Talos support |
| Data path | `/var/lib/longhorn` (OS disk) | Single disk setup, simpler than dedicated disk with UserVolumeConfig |
| Replica count | 1 | Single-node cluster — additional replicas waste disk with no HA benefit |
| Default StorageClass | Yes | Only storage provider, avoids boilerplate `storageClassName` on every PVC |
| Backup target | S3 (Minio on TrueNAS) | Offsite backup to separate hardware |
| Backup schedule | Daily at 2 AM, retain 7 | Good balance of protection and storage usage |
| Backup config | Longhorn RecurringJob CRD | Fully declarative, survives cluster rebuild, consistent with GitOps |
| UI access | HTTPRoute via Traefik | Accessible at `longhorn.xmple.io`, matches ArgoCD pattern |
| UI authentication | None | Homelab on private network, acceptable risk |
| Namespace | `longhorn-system` | Longhorn's conventional namespace |

## Talos Machine Config Patch

Longhorn requires the kubelet to bind-mount its data directory from the host. New patch file `patches/longhorn.yaml`:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options:
          - bind
          - rshared
          - rw
```

Applied during `task reconfigure` or initial `task setup`. Requires node reboot to take effect (handled by reconfigure's reboot step).

## Wrapper Helm Chart

```
cluster/apps/longhorn/
  Chart.yaml          # Depends on longhorn/longhorn 1.11.0
  values.yaml         # Config nested under longhorn: key
  config.json         # ArgoCD discovery metadata
  templates/
    recurring-job.yaml   # Daily S3 backup schedule
    httproute.yaml       # UI access at longhorn.xmple.io
```

### Chart.yaml

```yaml
apiVersion: v2
name: longhorn
version: 0.1.0
dependencies:
  - name: longhorn
    version: 1.11.0
    repository: https://charts.longhorn.io
```

### config.json

```json
{
  "appName": "longhorn",
  "namespace": "longhorn-system",
  "chartPath": "cluster/apps/longhorn"
}
```

### Key values.yaml Settings

All values nested under `longhorn:` (Helm dependency scoping):

```yaml
longhorn:
  defaultSettings:
    defaultReplicaCount: 1
    defaultDataPath: /var/lib/longhorn
    backupTarget: "s3://<bucket>@<region>/"
    backupTargetCredentialSecret: longhorn-s3-secret
  persistence:
    defaultClass: true
    defaultClassReplicaCount: 1
```

## S3 Backup Configuration

### Credentials Secret

Created by Taskfile during bootstrap (not stored in git):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-s3-secret
  namespace: longhorn-system
stringData:
  AWS_ACCESS_KEY_ID: <from vars.yaml>
  AWS_SECRET_ACCESS_KEY: <from vars.yaml>
  AWS_ENDPOINTS: <from vars.yaml>
```

### RecurringJob CRD

Declarative backup schedule in `templates/recurring-job.yaml`:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: daily-backup
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"
  task: backup
  groups:
    - default
  retain: 7
  concurrency: 1
```

Applies to all volumes in the `default` group (Longhorn's default assignment for new volumes).

### New vars.yaml Entries

```yaml
longhorn_version: "1.11.0"
longhorn_s3_endpoint: "https://truenas.local:9000"
longhorn_s3_bucket: "longhorn-backup"
longhorn_s3_region: "us-east-1"
longhorn_s3_access_key: "<access-key>"
longhorn_s3_secret_key: "<secret-key>"
```

## HTTPRoute for UI

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn-ui
  namespace: longhorn-system
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: websecure
      group: gateway.networking.k8s.io
      kind: Gateway
  hostnames:
    - longhorn.xmple.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: longhorn-frontend
          namespace: longhorn-system
          port: 80
          group: ""
          kind: Service
          weight: 1
```

Explicit API server defaults (group, kind, weight, path type) prevent ArgoCD drift.

## Bootstrap Order (Updated)

```
task setup
  → ... → kubeconfig
  → cilium          (CNI)
  → traefik         (networking)
  → cert-manager    (TLS)
  → longhorn        (storage — NEW)
  → argocd          (GitOps, discovers longhorn via config.json)
  → health check
```

Longhorn installs after cert-manager and before ArgoCD so persistent storage is available before ArgoCD starts.

## Taskfile Task

```yaml
longhorn:
  desc: Install/upgrade Longhorn
  cmds:
    - helm repo add longhorn https://charts.longhorn.io --force-update
    - helm dependency build cluster/apps/longhorn
    - kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    - >-
      kubectl create secret generic longhorn-s3-secret -n longhorn-system
      --from-literal=AWS_ACCESS_KEY_ID={{.LONGHORN_S3_ACCESS_KEY}}
      --from-literal=AWS_SECRET_ACCESS_KEY={{.LONGHORN_S3_SECRET_KEY}}
      --from-literal=AWS_ENDPOINTS={{.LONGHORN_S3_ENDPOINT}}
      --dry-run=client -o yaml | kubectl apply -f -
    - >-
      helm upgrade --install longhorn cluster/apps/longhorn
      --namespace longhorn-system
      --create-namespace
      --force-conflicts
      --wait --timeout 10m
```

Longer timeout (10m vs 5m) because Longhorn deploys many components (manager, driver, UI, CSI plugin).

## CLAUDE.md Updates

Add to the secrets table:
- `longhorn-s3-secret` in `longhorn-system`, created by `task longhorn` from vars.yaml

Add to critical gotchas:
- Longhorn on Talos requires kubelet extra mount for `/var/lib/longhorn` — patch must be applied and node rebooted before Longhorn install
- After reinstalling Longhorn, existing PVCs may need manual reattachment

## Post-Bootstrap Workflow

After ArgoCD is running, Longhorn upgrades go through git:
1. Bump version in `cluster/apps/longhorn/Chart.yaml`
2. Push to `main`
3. ArgoCD auto-syncs the change

Backup configuration changes (retention, schedule, S3 target) also go through git by modifying `values.yaml` or `templates/recurring-job.yaml`.
