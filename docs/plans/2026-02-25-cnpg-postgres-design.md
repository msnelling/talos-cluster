# CloudNativePG PostgreSQL Cluster Design

**Date:** 2026-02-25
**Status:** Approved

## Goal

Run an in-cluster PostgreSQL server to replace the external `truenas.local` dependency. Provides a shared, highly available database for Gitea and future applications.

## Architecture

### Two-Layer Deployment

CloudNativePG separates the **operator** (CRDs + controller) from **cluster instances** (actual PostgreSQL pods). This maps to two wrapper Helm charts:

| Component | Wrapper Chart | Upstream Chart | Namespace | ArgoCD Group |
|---|---|---|---|---|
| CNPG Operator | `cluster/apps/cnpg-operator/` | `cnpg/cloudnative-pg` v0.27.1 | `cnpg-system` | platform |
| PostgreSQL Cluster | `cluster/apps/cnpg-cluster/` | `cnpg/cluster` | `cnpg-cluster` | data (new) |

ArgoCD handles CRD-before-CR ordering natively, so the operator installs before the cluster CR is applied.

### PostgreSQL Cluster Topology

- **3 instances**: 1 primary (read-write) + 2 replicas (read-only) with PostgreSQL streaming replication
- **Automatic failover**: CNPG promotes a replica if the primary fails (typically <10s)
- **Shared cluster model**: One cluster, multiple databases. Start with a `gitea` database, add more via SQL as needed

### Storage: Avoiding Double Replication

CNPG's streaming replication already maintains 3 full copies of the data (one per instance). Longhorn's default `numberOfReplicas: 2` would create 6 copies total, which is wasteful.

**Solution**: A dedicated `longhorn-single-replica` StorageClass with `numberOfReplicas: 1`:

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

This yields 3 copies total (one per PostgreSQL instance, each on a different node). The StorageClass is templated in the `cnpg-cluster` wrapper chart.

**PVC sizing**: 10Gi per instance (tunable in values.yaml).

### Backups

CNPG uses Barman for S3-based backups, reusing the same S3 endpoint as Longhorn:

- **Continuous WAL archiving**: every WAL segment shipped to S3 as produced, enabling point-in-time recovery
- **Scheduled base backups**: daily full snapshots to bound WAL replay during recovery
- **Retention**: 7 daily backups (configurable)

S3 credentials are provided via a Kubernetes secret created by `task components:cnpg-secrets`.

### Networking

CNPG auto-creates three services:

| Service | Target | Use Case |
|---|---|---|
| `cnpg-cluster-rw` | Primary only | App connections (read-write) |
| `cnpg-cluster-ro` | Replicas only | Read-only queries |
| `cnpg-cluster-r` | All instances | Any read |

No external exposure (no HTTPRoute). Apps connect via the `-rw` service within the cluster (e.g., `cnpg-cluster-rw.cnpg-cluster.svc`).

### Resource Sizing

Per PostgreSQL instance (homelab defaults):

| Resource | Request | Limit |
|---|---|---|
| Memory | 256Mi | 1Gi |
| CPU | 100m | — |

### Security

CNPG runs as non-root by default. No `privileged` PodSecurity label needed — compatible with Talos's default `baseline` enforcement.

CNPG auto-generates a `<cluster-name>-app` secret with connection credentials (host, port, dbname, user, password, URI).

## New ArgoCD Group: `data`

A new app group at `cluster/groups/data/` for data services:

- Registered in the ArgoCD chart alongside networking, platform, services, db3000
- Starts with `cnpg-cluster` as its only member
- Room to add future data services (Redis, etc.)

## Secrets

New `task components:cnpg-secrets` in `taskfiles/components.yaml`:

| Secret | Namespace | Contents |
|---|---|---|
| `cnpg-s3-creds` | `cnpg-cluster` | S3 endpoint, bucket, access key, secret key for Barman backups |

Additional vars in `vars.yaml`:

- `cnpg_s3_endpoint`, `cnpg_s3_bucket`, `cnpg_s3_access_key`, `cnpg_s3_secret_key`
- Or reuse existing Longhorn S3 vars if same bucket/credentials

## Gitea Migration Path

1. Deploy CNPG operator and cluster
2. Verify the `gitea` database is bootstrapped and accessible
3. `pg_dump` from `truenas.local`, `pg_restore` into the in-cluster instance
4. Update `vars.yaml`: `gitea_postgres_host: "cnpg-cluster-rw.cnpg-cluster.svc"`
5. Re-run `task components:gitea-secrets` to update the connection secret
6. Restart Gitea pods to pick up the new connection
7. Verify Gitea works, then decommission the truenas PostgreSQL

## References

- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/)
- [CloudNativePG Helm Charts](https://github.com/cloudnative-pg/charts)
- [CNPG Cluster Chart](https://github.com/cloudnative-pg/charts/tree/main/charts/cluster)
