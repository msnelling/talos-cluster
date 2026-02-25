# CloudNativePG + pgAdmin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a highly available PostgreSQL cluster with pgAdmin web UI, managed by CloudNativePG operator, as a shared database service for Gitea and future apps.

**Architecture:** CNPG operator (platform group) installs CRDs/controller. CNPG cluster + pgAdmin (new data group) deploy the 3-instance PostgreSQL cluster and management UI. A dedicated single-replica Longhorn StorageClass avoids double-replication. S3 backups via Barman for point-in-time recovery.

**Tech Stack:** CloudNativePG operator v0.27.1 (app v1.28.1), CNPG cluster chart v0.5.0, pgAdmin4 chart v1.59.0 (app v9.11), Longhorn storage, Barman S3 backups

**Design doc:** `docs/plans/2026-02-25-cnpg-postgres-design.md`

---

### Task 1: Create CNPG Operator Wrapper Chart

**Files:**
- Create: `cluster/apps/cnpg-operator/Chart.yaml`
- Create: `cluster/apps/cnpg-operator/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: cnpg-operator
version: 0.1.0
dependencies:
  - name: cloudnative-pg
    version: "0.27.1"
    repository: https://cloudnative-pg.github.io/charts
```

**Step 2: Create values.yaml**

Operator defaults are production-ready (replicaCount: 1, CRDs installed, webhook enabled). No overrides needed per CLAUDE.md rule: "Only override upstream defaults when necessary."

```yaml
cloudnative-pg: {}
```

**Step 3: Validate the chart**

Run:
```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm dependency build cluster/apps/cnpg-operator
helm lint cluster/apps/cnpg-operator
helm template test cluster/apps/cnpg-operator | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: lint passes, kubeconform passes (some CNPG CRDs may show "skipped" — that's fine with `-ignore-missing-schemas`).

**Step 4: Commit**

```bash
git add cluster/apps/cnpg-operator/
git commit -m "feat: add CNPG operator wrapper chart"
```

---

### Task 2: Add CNPG Operator to Platform Group

**Files:**
- Modify: `cluster/groups/platform/values.yaml` (append to `apps:` list)

**Step 1: Add cnpg-operator entry**

Append to the end of the `apps:` list in `cluster/groups/platform/values.yaml`:

```yaml
  - name: cnpg-operator
    namespace: cnpg-system
    path: cluster/apps/cnpg-operator
```

The full file should end with:

```yaml
  - name: intel-gpu
    namespace: intel-gpu
    path: cluster/apps/intel-gpu
  - name: cnpg-operator
    namespace: cnpg-system
    path: cluster/apps/cnpg-operator
```

**Step 2: Validate the platform group still lints**

Run:
```bash
helm lint cluster/groups/platform
helm template test cluster/groups/platform | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: passes.

**Step 3: Commit**

```bash
git add cluster/groups/platform/values.yaml
git commit -m "feat: add cnpg-operator to platform group"
```

---

### Task 3: Create CNPG Cluster Wrapper Chart

**Files:**
- Create: `cluster/apps/cnpg-cluster/Chart.yaml`
- Create: `cluster/apps/cnpg-cluster/values.yaml`
- Create: `cluster/apps/cnpg-cluster/templates/storageclass.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: cnpg-cluster
version: 0.1.0
dependencies:
  - name: cluster
    version: "0.5.0"
    repository: https://cloudnative-pg.github.io/charts
```

**Step 2: Create templates/storageclass.yaml**

Dedicated StorageClass with single Longhorn replica to avoid double-replication (CNPG streaming replication already maintains 3 copies).

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-single-replica
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
```

**Step 3: Create values.yaml**

Key details verified against `helm show values cnpg/cluster --version 0.5.0`:
- `cluster.initdb` (NOT `recovery.initdb`) is used in `standalone` mode for bootstrap
- `cluster.affinity.topologyKey` defaults to `topology.kubernetes.io/zone` — must change to `kubernetes.io/hostname` for bare-metal
- `backups.secret.create` defaults to `true` — set to `false` since we provide our own secret
- `backups.wal.encryption` and `backups.data.encryption` default to `AES256` — set to empty for MinIO compatibility
- `backups.endpointURL` must be in values (not in the secret) — CNPG reads it from the Cluster CR spec

```yaml
cluster:
  mode: standalone

  cluster:
    instances: 3

    storage:
      size: 10Gi
      storageClass: longhorn-single-replica

    resources:
      requests:
        memory: 256Mi
        cpu: 100m
      limits:
        memory: 1Gi

    affinity:
      topologyKey: kubernetes.io/hostname

    enableSuperuserAccess: true

    initdb:
      database: gitea
      owner: gitea

  backups:
    enabled: true
    endpointURL: "https://truenas.local:9000"  # Set to your S3-compatible endpoint
    provider: s3
    s3:
      region: "us-east-1"
      bucket: "cnpg-backup"
      path: "/"
    secret:
      create: false
      name: cnpg-s3-creds
    wal:
      compression: gzip
      encryption: ""
      maxParallel: 1
    data:
      compression: gzip
      encryption: ""
      jobs: 2
    scheduledBackups:
      - name: daily-backup
        schedule: "0 0 0 * * *"
        backupOwnerReference: self
        method: barmanObjectStore
    retentionPolicy: "7d"
```

**Step 4: Validate the chart**

Run:
```bash
helm dependency build cluster/apps/cnpg-cluster
helm lint cluster/apps/cnpg-cluster
helm template test cluster/apps/cnpg-cluster | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: lint passes. The `Cluster` CRD will show as "skipped" in kubeconform (missing schema) — expected.

**Step 5: Commit**

```bash
git add cluster/apps/cnpg-cluster/
git commit -m "feat: add CNPG cluster wrapper chart with single-replica StorageClass"
```

---

### Task 4: Create pgAdmin Wrapper Chart

**Files:**
- Create: `cluster/apps/pgadmin/Chart.yaml`
- Create: `cluster/apps/pgadmin/values.yaml`
- Create: `cluster/apps/pgadmin/templates/httproute.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: pgadmin
version: 0.1.0
dependencies:
  - name: pgadmin4
    version: "1.59.0"
    repository: https://helm.runix.net
```

**Step 2: Create values.yaml**

Key details verified against `helm show values runix/pgadmin4 --version 1.59.0`:
- `existingSecret` pulls only the password — `env.email` must still be set in values (not sensitive)
- `secretKeys.pgadminPasswordKey` defaults to `password` — matches our secret key
- `serverDefinitions.servers` uses inline YAML, rendered as JSON by the chart
- `persistentVolume.size` defaults to `10Gi` — override to `1Gi` (pgAdmin config data is tiny)
- The chart has a built-in `httpRoute` option but we use our own template for consistency with gitea/argocd patterns

```yaml
pgadmin4:
  existingSecret: pgadmin-credentials
  secretKeys:
    pgadminPasswordKey: password

  env:
    email: admin@example.com
    enhanced_cookie_protection: "False"

  serverDefinitions:
    enabled: true
    resourceType: ConfigMap
    servers:
      cnpgCluster:
        Name: "CNPG Cluster (primary)"
        Group: "Servers"
        Port: 5432
        Username: postgres
        Host: cnpg-cluster-cluster-rw
        SSLMode: prefer
        MaintenanceDB: postgres

  persistentVolume:
    enabled: true
    size: 1Gi

  resources:
    requests:
      memory: 128Mi
    limits:
      memory: 512Mi
```

**Important — Service name for the CNPG cluster:** The CNPG cluster chart creates services named `<release>-<chartname>-rw`. When ArgoCD deploys the `cnpg-cluster` Application, the Helm release name is `cnpg-cluster` and the chart name is `cluster`, producing `cnpg-cluster-cluster-rw`. Verify after Task 3 with: `helm template cnpg-cluster cluster/apps/cnpg-cluster | grep 'kind: Service' -A 5`.

**Step 3: Create templates/httproute.yaml**

Follows the exact pattern from `cluster/apps/gitea/templates/httproute.yaml`. All Gateway API defaults (group, kind, weight, path type) must be explicit per CLAUDE.md to prevent ArgoCD drift.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pgadmin
  namespace: {{ .Release.Namespace }}
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: traefik
      sectionName: websecure
  hostnames:
    - pgadmin.xmple.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: pgadmin-pgadmin4
          port: 80
          weight: 1
```

**Service name reasoning:** The `runix/pgadmin4` chart names the service `{{ .Release.Name }}-pgadmin4`. When ArgoCD deploys Application `pgadmin`, the release name is `pgadmin`, producing `pgadmin-pgadmin4`.

**Step 4: Validate the chart**

Run:
```bash
helm repo add runix https://helm.runix.net --force-update
helm dependency build cluster/apps/pgadmin
helm lint cluster/apps/pgadmin
helm template pgadmin cluster/apps/pgadmin | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: passes. Also verify service name:
```bash
helm template pgadmin cluster/apps/pgadmin | grep 'kind: Service' -A 5
```
Expected: service named `pgadmin-pgadmin4`.

**Step 5: Commit**

```bash
git add cluster/apps/pgadmin/
git commit -m "feat: add pgAdmin wrapper chart with HTTPRoute"
```

---

### Task 5: Create Data App Group

**Files:**
- Create: `cluster/groups/data/Chart.yaml`
- Create: `cluster/groups/data/values.yaml`
- Create: `cluster/groups/data/templates/applications.yaml`

**Step 1: Create Chart.yaml**

Follows `cluster/groups/services/Chart.yaml` pattern exactly.

```yaml
apiVersion: v2
name: app-data
version: 0.1.0
description: Data services group (cnpg-cluster, pgadmin)
```

**Step 2: Create values.yaml**

Follows `cluster/groups/services/values.yaml` pattern. Both apps deploy into `cnpg-cluster` namespace.

```yaml
repoURL: git@github.com:xmple/talos-cluster.git
targetRevision: main
project: cluster

autoSync: true

apps:
  - name: cnpg-cluster
    namespace: cnpg-cluster
    path: cluster/apps/cnpg-cluster
  - name: pgadmin
    namespace: cnpg-cluster
    path: cluster/apps/pgadmin
```

**Step 3: Create templates/applications.yaml**

Copy exactly from `cluster/groups/services/templates/applications.yaml` — it is the canonical simple pattern. Do NOT copy from db3000 (it has namespace templates).

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

**Step 4: Validate the group**

Run:
```bash
helm lint cluster/groups/data
helm template test cluster/groups/data | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: passes.

**Step 5: Commit**

```bash
git add cluster/groups/data/
git commit -m "feat: add data app group for CNPG cluster and pgAdmin"
```

---

### Task 6: Register Data Group in ArgoCD Chart

**Files:**
- Create: `cluster/apps/argocd/templates/app-group-data.yaml`

**Step 1: Create the app-group template**

Follows exactly the pattern in `cluster/apps/argocd/templates/app-group-services.yaml`. Only `name` and `path` differ.

```yaml
{{- if .Capabilities.APIVersions.Has "argoproj.io/v1alpha1/Application" }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-data
  namespace: argocd
spec:
  project: cluster
  source:
    repoURL: git@github.com:xmple/talos-cluster.git
    targetRevision: main
    path: cluster/groups/data
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

**Step 2: Validate the ArgoCD chart**

Run:
```bash
helm dependency build cluster/apps/argocd
helm lint cluster/apps/argocd
helm template test cluster/apps/argocd | kubeconform -strict -ignore-missing-schemas -summary
```
Expected: passes. Verify the new Application appears:
```bash
helm template test cluster/apps/argocd | grep 'name: app-data'
```
Expected: `name: app-data` appears.

**Step 3: Commit**

```bash
git add cluster/apps/argocd/templates/app-group-data.yaml
git commit -m "feat: register data group in ArgoCD chart"
```

---

### Task 7: Add Secrets Task and Variables

**Files:**
- Modify: `taskfiles/components.yaml` (add `cnpg-secrets` task)
- Modify: `Taskfile.yaml` (add var declarations)
- Modify: `vars.yaml.example` (add placeholder vars)

**Step 1: Add cnpg-secrets task to taskfiles/components.yaml**

Insert after the `gitea-secrets` task (line 191) and before `renovate-secret` (line 192). Follows the heredoc + stringData pattern exactly.

```yaml
  cnpg-secrets:
    desc: Create CNPG S3 backup and pgAdmin secrets (namespace created by ArgoCD)
    cmds:
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: cnpg-s3-creds
          namespace: cnpg-cluster
        type: Opaque
        stringData:
          ACCESS_KEY_ID: "{{.CNPG_S3_ACCESS_KEY}}"
          ACCESS_SECRET_KEY: "{{.CNPG_S3_SECRET_KEY}}"
        EOF
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: pgadmin-credentials
          namespace: cnpg-cluster
        type: Opaque
        stringData:
          password: "{{.PGADMIN_PASSWORD}}"
        EOF
```

**Note on CNPG S3 secret keys:** CNPG's Barman expects `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` in the backup credentials secret (per [CNPG backup docs](https://cloudnative-pg.io/documentation/current/backup_barmanobjectstore/)).

**Step 2: Add var declarations to Taskfile.yaml**

Insert after the `RENOVATE_GITHUB_APP_ID` block (line 86) and before `# Multi-node helpers` (line 87):

```yaml
  # CNPG PostgreSQL
  CNPG_S3_ACCESS_KEY:
    sh: yq '.cnpg_s3_access_key' vars.yaml
  CNPG_S3_SECRET_KEY:
    sh: yq '.cnpg_s3_secret_key' vars.yaml
  # pgAdmin
  PGADMIN_PASSWORD:
    sh: yq '.pgadmin_password' vars.yaml
```

**Step 3: Add placeholder vars to vars.yaml.example**

Append after the `renovate_github_app_id` line at the end of the file:

```yaml

# CloudNativePG
cnpg_s3_access_key: "your-cnpg-s3-access-key"
cnpg_s3_secret_key: "your-cnpg-s3-secret-key"

# pgAdmin
pgadmin_password: "your-pgadmin-password"
```

**Step 4: Commit**

```bash
git add taskfiles/components.yaml Taskfile.yaml vars.yaml.example
git commit -m "feat: add cnpg-secrets task and variables"
```

---

### Task 8: Update CLAUDE.md Secrets Table

**Files:**
- Modify: `CLAUDE.md` (add to secrets table)

**Step 1: Add new secrets to the table**

Add these rows to the secrets table in CLAUDE.md, after the `gitea-config-secrets` row:

```
| `cnpg-s3-creds` | cnpg-cluster | `task components:cnpg-secrets` (from vars.yaml) |
| `pgadmin-credentials` | cnpg-cluster | `task components:cnpg-secrets` (from vars.yaml) |
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CNPG and pgAdmin secrets to CLAUDE.md"
```

---

### Task 9: Final Validation

**No files changed — validation only.**

**Step 1: Run full validation across all charts**

```bash
# cnpg-operator
helm dependency build cluster/apps/cnpg-operator && helm lint cluster/apps/cnpg-operator && helm template test cluster/apps/cnpg-operator | kubeconform -strict -ignore-missing-schemas -summary

# cnpg-cluster
helm dependency build cluster/apps/cnpg-cluster && helm lint cluster/apps/cnpg-cluster && helm template test cluster/apps/cnpg-cluster | kubeconform -strict -ignore-missing-schemas -summary

# pgadmin
helm dependency build cluster/apps/pgadmin && helm lint cluster/apps/pgadmin && helm template pgadmin cluster/apps/pgadmin | kubeconform -strict -ignore-missing-schemas -summary

# data group
helm lint cluster/groups/data && helm template test cluster/groups/data | kubeconform -strict -ignore-missing-schemas -summary

# argocd (rebuild deps to pick up any changes)
helm dependency build cluster/apps/argocd && helm lint cluster/apps/argocd && helm template test cluster/apps/argocd | kubeconform -strict -ignore-missing-schemas -summary
```

Expected: all pass.

**Step 2: Verify CNPG cluster service name**

```bash
helm template cnpg-cluster cluster/apps/cnpg-cluster | grep 'kind: Service' -A 5
```

Note the `-rw` service name — it should be used in pgAdmin's `serverDefinitions.servers.cnpgCluster.Host` value. If the service name doesn't match, update `cluster/apps/pgadmin/values.yaml` accordingly.

**Step 3: Verify pgAdmin service name**

```bash
helm template pgadmin cluster/apps/pgadmin | grep 'kind: Service' -A 5
```

Should show `pgadmin-pgadmin4`. Must match `backendRefs[].name` in `cluster/apps/pgadmin/templates/httproute.yaml`.

---

### Task 10: Squash Commits and Push

**Step 1: Verify all changes**

```bash
git log --oneline feat/cnpg-postgres --not main
git diff main..feat/cnpg-postgres --stat
```

**Step 2: Push and create PR**

```bash
git push -u origin feat/cnpg-postgres
```

---

## Post-Merge Deployment Steps (manual, not part of this plan)

After the PR is merged to `main`:

1. **ArgoCD syncs automatically** — the platform group installs the CNPG operator, then the data group creates the PostgreSQL cluster and pgAdmin
2. **Wait for operator**: `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cloudnative-pg -n cnpg-system --timeout=5m`
3. **Wait for namespace**: `kubectl get namespace cnpg-cluster` (created by ArgoCD via `CreateNamespace=true`)
4. **Create secrets**: `task components:cnpg-secrets`
5. **Monitor cluster bootstrap**: `kubectl get clusters.postgresql.cnpg.io -n cnpg-cluster -w`
6. **Verify pgAdmin**: browse to `pgadmin.xmple.io`

## Gitea Migration (separate follow-up)

1. `pg_dump` from `truenas.local`
2. `pg_restore` into in-cluster CNPG
3. Update `vars.yaml`: `gitea_postgres_host: "cnpg-cluster-cluster-rw.cnpg-cluster.svc"`
4. `task components:gitea-secrets`
5. Restart Gitea pods
