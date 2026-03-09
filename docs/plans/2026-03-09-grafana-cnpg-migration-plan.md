# Grafana CNPG Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate Grafana's database from embedded SQLite to the existing CNPG PostgreSQL cluster.

**Architecture:** Add a `grafana` managed role to the CNPG cluster, wire credentials through the established secret pipeline, and configure Grafana to connect via `GF_DATABASE_*` environment variables.

**Tech Stack:** CNPG PostgreSQL, kube-prometheus-stack Helm chart, Taskfile

---

### Task 1: Add `grafana` managed role to CNPG cluster

**Files:**
- Modify: `cluster/apps/cnpg-cluster/values.yaml:24-30`

**Step 1: Add the grafana role**

In `cluster/apps/cnpg-cluster/values.yaml`, add `grafana` with `createdb: true` to the `managedRoles` list:

```yaml
managedRoles:
  - name: gitea
    createdb: true
  - name: authelia
  - name: teslamate
  - name: hass
  - name: jellyseerr
  - name: grafana
    createdb: true
```

**Step 2: Validate the chart**

Run: `helm lint cluster/apps/cnpg-cluster && helm template test cluster/apps/cnpg-cluster | grep -A 5 'name: grafana'`

Expected: Lint passes, template output shows the grafana role with `createdb: true` and `passwordSecret.name: grafana-role-password`.

**Step 3: Commit**

```bash
git add cluster/apps/cnpg-cluster/values.yaml
git commit -m "feat: add grafana managed role to CNPG cluster"
```

---

### Task 2: Add `grafana` to cnpg-role-secrets task

**Files:**
- Modify: `taskfiles/components.yaml:306`

**Step 1: Add grafana to the ROLES variable**

In `taskfiles/components.yaml`, change line 306 from:

```yaml
      ROLES: gitea authelia teslamate hass jellyseerr
```

to:

```yaml
      ROLES: gitea authelia teslamate hass jellyseerr grafana
```

**Step 2: Commit**

```bash
git add taskfiles/components.yaml
git commit -m "feat: add grafana to cnpg-role-secrets task"
```

---

### Task 3: Add Grafana DB secret to monitoring-secrets task

**Files:**
- Modify: `taskfiles/components.yaml:53-84`

**Step 1: Add cnpg-role-secrets dependency and grafana-db-secrets creation**

In `taskfiles/components.yaml`, modify the `monitoring-secrets` task. Add `deps: [cnpg-role-secrets]` and append a new command block after the `grafana-admin` secret (after line 84):

```yaml
  monitoring-secrets:
    desc: Create secrets for observability stack (creates namespace if needed)
    deps: [cnpg-role-secrets]
    cmds:
      - kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
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
      - |
        GRAFANA_DB_PASS=$(kubectl get secret grafana-role-password -n cnpg-cluster -o jsonpath='{.data.password}' | base64 -d)
        cat <<EOF | kubectl apply -f -
        apiVersion: v1
        kind: Secret
        metadata:
          name: grafana-db-secrets
          namespace: monitoring
        type: Opaque
        stringData:
          GF_DATABASE_TYPE: "postgres"
          GF_DATABASE_HOST: "cnpg-cluster-rw.cnpg-cluster.svc:5432"
          GF_DATABASE_NAME: "grafana"
          GF_DATABASE_USER: "grafana"
          GF_DATABASE_PASSWORD: "${GRAFANA_DB_PASS}"
          GF_DATABASE_SSL_MODE: "require"
        EOF
```

Note: The last heredoc uses `<<EOF` (not `<<'EOF'`) so `${GRAFANA_DB_PASS}` is interpolated.

**Step 2: Commit**

```bash
git add taskfiles/components.yaml
git commit -m "feat: add grafana-db-secrets to monitoring-secrets task"
```

---

### Task 4: Configure Grafana to use PostgreSQL

**Files:**
- Modify: `cluster/apps/kube-prometheus-stack/values.yaml:25-39`

**Step 1: Update Grafana values**

In `cluster/apps/kube-prometheus-stack/values.yaml`, replace the `grafana:` section (lines 25-39) with:

```yaml
  grafana:
    admin:
      existingSecret: grafana-admin
      userKey: admin-user
      passwordKey: admin-password
    persistence:
      enabled: false
    envFromSecrets:
      - name: grafana-db-secrets
        optional: false
    additionalDataSources:
      - name: Loki
        type: loki
        url: http://loki-gateway.monitoring.svc:80
        access: proxy
        isDefault: false
```

Key changes:
- `persistence.enabled: false` — no SQLite PVC
- `envFromSecrets` — injects `GF_DATABASE_*` env vars from the secret created in Task 3

**Step 2: Validate the chart**

Run: `helm dependency build cluster/apps/kube-prometheus-stack && helm lint cluster/apps/kube-prometheus-stack`

Expected: Lint passes with no errors.

**Step 3: Verify envFromSecrets renders correctly**

Run: `helm template test cluster/apps/kube-prometheus-stack | grep -A 3 'envFrom'`

Expected: Output shows `secretRef` with `name: grafana-db-secrets`.

**Step 4: Commit**

```bash
git add cluster/apps/kube-prometheus-stack/values.yaml
git commit -m "feat: configure Grafana to use CNPG PostgreSQL instead of SQLite"
```

---

### Task 5: Update CLAUDE.md secrets table

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add grafana-db-secrets to the secrets table**

In the secrets table in `CLAUDE.md`, add a row for the new secret:

```
| `grafana-db-secrets` | monitoring | `task components:monitoring-secrets` (reads password from `grafana-role-password` in cnpg-cluster) |
```

Also add `grafana` to the existing `{role}-role-password` row description.

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add grafana-db-secrets to secrets table"
```
