# Grafana SQLite to CNPG PostgreSQL Migration

## Goal

Migrate Grafana's database backend from the default embedded SQLite to the existing CNPG PostgreSQL cluster. Fresh start — no data migration needed.

## Design

Follow the established pattern used by Gitea and Jellyseerr for connecting apps to CNPG.

### 1. CNPG Cluster — add `grafana` managed role

Add `grafana` with `createdb: true` to `managedRoles` in `cluster/apps/cnpg-cluster/values.yaml`. The CNPG operator will reconcile this role into PostgreSQL automatically.

### 2. cnpg-role-secrets task — add `grafana` to the loop

Add `grafana` to the role list in the `cnpg-role-secrets` task in `taskfiles/components.yaml`. This generates a `grafana-role-password` secret in the `cnpg-cluster` namespace.

### 3. monitoring-secrets task — create Grafana DB secret

- Add dependency on `cnpg-role-secrets`
- Read `grafana-role-password` from `cnpg-cluster` namespace
- Create `grafana-db-secrets` secret in `monitoring` namespace with connection details:
  - `GF_DATABASE_TYPE=postgres`
  - `GF_DATABASE_HOST=cnpg-cluster-rw.cnpg-cluster.svc:5432`
  - `GF_DATABASE_NAME=grafana`
  - `GF_DATABASE_USER=grafana`
  - `GF_DATABASE_PASSWORD=<from role secret>`
  - `GF_DATABASE_SSL_MODE=require`

### 4. Grafana Helm values

- Add `envFromSecrets` referencing `grafana-db-secrets` to inject `GF_DATABASE_*` env vars
- Set `persistence.enabled: false` (no SQLite PVC needed)

### 5. No group changes

Grafana stays in the observability group. CNPG stays in the data group.

## Data Flow

```
cnpg-role-secrets creates grafana-role-password in cnpg-cluster ns
  -> CNPG operator reconciles the role into PostgreSQL
  -> monitoring-secrets reads password, creates grafana-db-secrets in monitoring ns
  -> Grafana reads grafana-db-secrets via envFromSecrets, connects to cnpg-cluster-rw
```
