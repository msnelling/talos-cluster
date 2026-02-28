# Jellyseerr to Seerr Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the media-app library-based Jellyseerr chart with a wrapper around the official Seerr Helm chart.

**Architecture:** New wrapper chart at `cluster/db3000/seerr/` depends on `seerr-chart` v3.2.0 via OCI registry. The official chart provides StatefulSet, Service, PVC, and HTTPRoute. A static PV in the wrapper's templates binds the PVC to the existing Longhorn volume. Database credentials are injected via `extraEnvFrom`.

**Tech Stack:** Helm (OCI dependency), Longhorn CSI, Gateway API HTTPRoute, CNPG PostgreSQL

**Design doc:** `docs/plans/2026-02-28-jellyseerr-to-seerr-design.md`

---

### Task 1: Create the seerr wrapper chart

**Files:**
- Create: `cluster/db3000/seerr/Chart.yaml`
- Create: `cluster/db3000/seerr/values.yaml`
- Create: `cluster/db3000/seerr/templates/pv.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: seerr
version: 0.1.0
dependencies:
  - name: seerr-chart
    version: "3.2.0"
    repository: oci://ghcr.io/seerr-team/seerr
```

**Step 2: Create values.yaml**

Seerr chart values are nested under `seerr-chart:`. Key mappings from the old jellyseerr config:
- Image: no override (chart appVersion controls it)
- Port: Seerr serves on port 5055 internally, chart's service exposes port 80
- Database: via `extraEnvFrom` referencing `seerr-db-secrets`
- Persistence: bind to existing Longhorn volume via `config.persistence.volumeName`
- Route: official chart's HTTPRoute pointed at traefik-gateway

Gateway API gotcha from CLAUDE.md: explicit `group`, `kind`, `weight`, `path` values prevent ArgoCD drift. The Seerr chart's route template handles `parentRefs`, `hostnames`, and `matches` via values. Verify rendered output in Task 2.

```yaml
seerr-chart:
  fullnameOverride: seerr

  extraEnv:
    - name: TZ
      value: Europe/London

  extraEnvFrom:
    - secretRef:
        name: seerr-db-secrets

  config:
    persistence:
      size: 1Gi
      volumeName: db3000-jellyseerr-config

  route:
    main:
      enabled: true
      parentRefs:
        - name: traefik-gateway
          namespace: traefik
          sectionName: websecure
      hostnames:
        - db3000.xmple.io
      matches:
        - path:
            type: PathPrefix
            value: /

  resources:
    requests:
      memory: 1Gi
    limits:
      memory: 1Gi
```

**Step 3: Create templates/pv.yaml**

Static PV referencing the existing Longhorn volume. Matches the pattern from `cluster/lib/media-app/templates/pv.yaml` but hardcoded for this specific volume.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: db3000-jellyseerr-config
spec:
  capacity:
    storage: 1Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: db3000-jellyseerr-config
```

Note: `ReadWriteOnce` (not `ReadWriteOncePod`) matches the Seerr chart's PVC access mode.

**Step 4: Build dependencies**

Run: `helm dependency build cluster/db3000/seerr`
Expected: Downloads seerr-chart OCI package into `charts/`

**Step 5: Commit**

```bash
git add cluster/db3000/seerr/
git commit -m "feat(seerr): add wrapper chart for official Seerr Helm chart"
```

---

### Task 2: Validate the new chart

**Step 1: Lint the chart**

Run: `helm lint cluster/db3000/seerr`
Expected: No errors

**Step 2: Render and inspect templates**

Run: `helm template seerr cluster/db3000/seerr`

Verify rendered output includes:
- StatefulSet with image `ghcr.io/seerr-team/seerr:v3.0.1`
- Service on port 80
- PVC with `volumeName: db3000-jellyseerr-config`
- PV with CSI volumeHandle `db3000-jellyseerr-config`
- HTTPRoute with parentRef `traefik-gateway`, hostname `db3000.xmple.io`, path `/`
- `extraEnvFrom` with `seerr-db-secrets`
- `TZ: Europe/London` env var

**Step 3: Check for ArgoCD drift risks**

Inspect the rendered HTTPRoute for missing API server defaults (group, kind, weight on backendRefs). If any are missing, add explicit values in `values.yaml` or note the chart handles them.

**Step 4: Validate with kubeconform**

Run: `helm template seerr cluster/db3000/seerr | kubeconform -strict -ignore-missing-schemas -summary`
Expected: No errors

---

### Task 3: Delete the old jellyseerr chart

**Files:**
- Delete: `cluster/db3000/jellyseerr/` (entire directory)

**Step 1: Remove the directory**

Run: `rm -rf cluster/db3000/jellyseerr`

**Step 2: Commit**

```bash
git add -A cluster/db3000/jellyseerr/
git commit -m "feat(seerr): remove old jellyseerr chart"
```

---

### Task 4: Update ArgoCD group and supporting files

**Files:**
- Modify: `cluster/groups/db3000/values.yaml:21-22`
- Modify: `taskfiles/components.yaml:152-166`
- Modify: `vars.yaml.example:75-76`
- Modify: `CLAUDE.md` (secrets table, ~line 247)

**Step 1: Update db3000 group**

In `cluster/groups/db3000/values.yaml`, replace the jellyseerr entry:

```yaml
# old
  - name: jellyseerr
    path: cluster/db3000/jellyseerr

# new
  - name: seerr
    path: cluster/db3000/seerr
```

**Step 2: Rename secret in taskfiles/components.yaml**

Replace the `jellyseerr-db-secrets` block (lines 152-166) with:

```yaml
      - |
        cat <<'EOF' | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: seerr-db-secrets
          namespace: db3000
        type: Opaque
        stringData:
          DB_TYPE: "postgres"
          DB_HOST: "cnpg-cluster-rw.cnpg-cluster.svc"
          DB_PORT: "5432"
          DB_USER: "jellyseerr"
          DB_PASS: "{{.SEERR_POSTGRES_PASSWORD}}"
          DB_NAME: "jellyseerr"
        EOF
```

Note: DB_USER and DB_NAME stay as `jellyseerr` — those are PostgreSQL identifiers, not app names.

**Step 3: Update vars.yaml.example**

```yaml
# old
# Jellyseerr database
jellyseerr_postgres_password: "your-jellyseerr-db-password"

# new
# Seerr database
seerr_postgres_password: "your-seerr-db-password"
```

**Step 4: Add secret to CLAUDE.md secrets table**

Add this row after the `gluetun-auth-secrets` entry (around line 247):

```
| `seerr-db-secrets` | db3000 | `task components:db3000-secrets` (from vars.yaml) |
```

**Step 5: Commit**

```bash
git add cluster/groups/db3000/values.yaml taskfiles/components.yaml vars.yaml.example CLAUDE.md
git commit -m "feat(seerr): update group, secrets, and docs for jellyseerr→seerr rename"
```

---

### Post-merge manual steps (not automated)

These steps must be performed after the PR is merged and ArgoCD syncs:

1. **Update `vars.yaml`**: Rename `jellyseerr_postgres_password` to `seerr_postgres_password` (same value)
2. **Re-apply secrets**: Run `task components:db3000-secrets` to create the renamed `seerr-db-secrets`
3. **Delete old secret**: `kubectl delete secret jellyseerr-db-secrets -n db3000`
4. **Verify ArgoCD sync**: Check that the `seerr` Application is healthy and the old `jellyseerr` Application is pruned
5. **Verify Seerr starts**: Check pod logs for successful startup and auto-migration from Jellyseerr
