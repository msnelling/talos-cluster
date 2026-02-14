# Gitea Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy Gitea to the Lenovo Talos cluster using the wrapper Helm chart pattern, connecting to the restored Longhorn volume and external PostgreSQL database.

**Architecture:** Wrapper Helm chart at `cluster/apps/gitea/` auto-discovered by the existing `cluster-apps` ApplicationSet. Gitea connects to an external PostgreSQL database, uses a restored Longhorn volume for git data, Valkey for cache/sessions, and MinIO for Actions artifacts. HTTPS is routed through Traefik via HTTPRoute; SSH gets a dedicated Cilium LoadBalancer IP.

**Tech Stack:** Helm, Gitea chart v12.5.0, Cilium LB-IPAM, Traefik Gateway API, Longhorn, Valkey, external PostgreSQL, MinIO S3

---

### Task 1: Add Gitea variables to Taskfile and vars.yaml.example

**Files:**
- Modify: `Taskfile.yaml:29-53` (add new var declarations after existing ones)
- Modify: `vars.yaml.example:28-37` (add gitea section)

**Step 1: Add Gitea var declarations to Taskfile.yaml**

Add the following after the `VPN_PROXY_PASSWORD` var block (around line 53), before the `# Multi-node helpers` comment:

```yaml
  GITEA_POSTGRES_HOST:
    sh: yq '.gitea_postgres_host' vars.yaml
  GITEA_POSTGRES_DB:
    sh: yq '.gitea_postgres_db' vars.yaml
  GITEA_POSTGRES_USER:
    sh: yq '.gitea_postgres_user' vars.yaml
  GITEA_POSTGRES_PASSWORD:
    sh: yq '.gitea_postgres_password' vars.yaml
  GITEA_ADMIN_USER:
    sh: yq '.gitea_admin_user' vars.yaml
  GITEA_ADMIN_PASSWORD:
    sh: yq '.gitea_admin_password' vars.yaml
  GITEA_ADMIN_EMAIL:
    sh: yq '.gitea_admin_email' vars.yaml
  GITEA_OAUTH_CLIENT_ID:
    sh: yq '.gitea_oauth_client_id' vars.yaml
  GITEA_OAUTH_CLIENT_SECRET:
    sh: yq '.gitea_oauth_client_secret' vars.yaml
  GITEA_SMTP_USER:
    sh: yq '.gitea_smtp_user' vars.yaml
  GITEA_SMTP_PASSWORD:
    sh: yq '.gitea_smtp_password' vars.yaml
  GITEA_MINIO_ACCESS_KEY:
    sh: yq '.gitea_minio_access_key' vars.yaml
  GITEA_MINIO_SECRET_KEY:
    sh: yq '.gitea_minio_secret_key' vars.yaml
  GITEA_SECRET_KEY:
    sh: yq '.gitea_secret_key' vars.yaml
  GITEA_SSH_IP:
    sh: yq '.gitea_ssh_ip' vars.yaml
```

**Step 2: Add Gitea placeholders to vars.yaml.example**

Append after the VPN section at the end of the file:

```yaml

# Gitea
gitea_postgres_host: "truenas.local"
gitea_postgres_db: "gitea"
gitea_postgres_user: "gitea"
gitea_postgres_password: "your-gitea-db-password"
gitea_admin_user: "admin"
gitea_admin_password: "your-gitea-admin-password"
gitea_admin_email: "admin@example.com"
gitea_oauth_client_id: "your-github-oauth-client-id"
gitea_oauth_client_secret: "your-github-oauth-client-secret"
gitea_smtp_user: "your-smtp-username"
gitea_smtp_password: "your-smtp-password"
gitea_minio_access_key: "your-minio-access-key"
gitea_minio_secret_key: "your-minio-secret-key"
gitea_secret_key: "your-gitea-secret-key"
gitea_ssh_ip: "10.1.1.62"
```

**Step 3: Add actual values to vars.yaml**

The user must fill in `vars.yaml` with real secrets. This file is git-ignored.

**Step 4: Commit**

```bash
git add Taskfile.yaml vars.yaml.example
git commit -m "Add Gitea variable declarations to Taskfile and vars.yaml.example"
```

---

### Task 2: Add gitea-secrets task to components.yaml

**Files:**
- Modify: `taskfiles/components.yaml:80-106` (add new task after `db3000-secrets`)

**Step 1: Add the gitea-secrets task**

Append to the end of `taskfiles/components.yaml`:

```yaml

  gitea-secrets:
    desc: Create Gitea namespace and secrets (Gitea itself is installed by ArgoCD)
    cmds:
      - kubectl create namespace gitea --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic gitea-admin-secret
          --namespace gitea
          --from-literal=username={{.GITEA_ADMIN_USER}}
          --from-literal=password={{.GITEA_ADMIN_PASSWORD}}
          --from-literal=email={{.GITEA_ADMIN_EMAIL}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic gitea-db-secret
          --namespace gitea
          --from-literal=host={{.GITEA_POSTGRES_HOST}}
          --from-literal=name={{.GITEA_POSTGRES_DB}}
          --from-literal=user={{.GITEA_POSTGRES_USER}}
          --from-literal=passwd={{.GITEA_POSTGRES_PASSWORD}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic gitea-oauth-secret
          --namespace gitea
          --from-literal=key={{.GITEA_OAUTH_CLIENT_ID}}
          --from-literal=secret={{.GITEA_OAUTH_CLIENT_SECRET}}
          --dry-run=client -o yaml | kubectl apply -f -
      - kubectl create secret generic gitea-config-secrets
          --namespace gitea
          --from-literal=security__SECRET_KEY={{.GITEA_SECRET_KEY}}
          --from-literal=database__HOST={{.GITEA_POSTGRES_HOST}}
          --from-literal=database__NAME={{.GITEA_POSTGRES_DB}}
          --from-literal=database__USER={{.GITEA_POSTGRES_USER}}
          --from-literal=database__PASSWD={{.GITEA_POSTGRES_PASSWORD}}
          --from-literal=mailer__USER={{.GITEA_SMTP_USER}}
          --from-literal=mailer__PASSWD={{.GITEA_SMTP_PASSWORD}}
          --from-literal=storage__MINIO_ACCESS_KEY_ID={{.GITEA_MINIO_ACCESS_KEY}}
          --from-literal=storage__MINIO_SECRET_ACCESS_KEY={{.GITEA_MINIO_SECRET_KEY}}
          --dry-run=client -o yaml | kubectl apply -f -
```

**Why two DB-related secrets?** `gitea-db-secret` is referenced by `gitea.additionalConfigSources` to inject `database__*` keys into app.ini, while `gitea-config-secrets` consolidates all sensitive app.ini values into one secret for `additionalConfigSources`. Actually, we should simplify — use a single `gitea-config-secrets` secret for all app.ini injection, and a separate `gitea-admin-secret` for the admin user (different Helm value: `gitea.admin.existingSecret`), and a separate `gitea-oauth-secret` (referenced by `gitea.oauth[].existingSecret`).

Revised — remove `gitea-db-secret`, keep only three secrets:
- `gitea-admin-secret` — for `gitea.admin.existingSecret`
- `gitea-oauth-secret` — for `gitea.oauth[].existingSecret`
- `gitea-config-secrets` — for `gitea.additionalConfigSources` (all sensitive app.ini values)

**Step 2: Verify task is listed**

Run: `task --list`
Expected: `gitea-secrets` appears under components namespace.

**Step 3: Commit**

```bash
git add taskfiles/components.yaml
git commit -m "Add gitea-secrets task to components Taskfile"
```

---

### Task 3: Add Gitea SSH IP pool to Cilium

**Files:**
- Modify: `cluster/apps/cilium/templates/ip-pool.yaml` (append new pool)

**Step 1: Add the gitea-pool**

Append to the end of `cluster/apps/cilium/templates/ip-pool.yaml`:

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: gitea-pool
spec:
  blocks:
    - start: {{ .Values.giteaSshIp }}
      stop: {{ .Values.giteaSshIp }}
  serviceSelector:
    matchLabels:
      app.kubernetes.io/part-of: gitea
```

Wait — the Cilium chart is a wrapper chart. Values in `cluster/apps/cilium/templates/` are scoped to the wrapper chart, not the upstream cilium dependency. So `.Values.giteaSshIp` would work if we add it to `cluster/apps/cilium/values.yaml` at the top level (not nested under `cilium:`).

However, looking at the existing `ip-pool.yaml`, the IPs are hardcoded (10.1.1.60, 10.1.1.61), not templated. Follow the same pattern — hardcode the IP. The user will set the actual IP during implementation.

Revised approach — hardcode:

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: gitea-pool
spec:
  blocks:
    - start: 10.1.1.62
      stop: 10.1.1.62
  serviceSelector:
    matchLabels:
      app.kubernetes.io/part-of: gitea
```

The user will confirm the exact IP during implementation (10.1.1.62 is a placeholder based on the existing pool pattern of .60, .61).

**Step 2: Commit**

```bash
git add cluster/apps/cilium/templates/ip-pool.yaml
git commit -m "Add Cilium LB-IPAM pool for Gitea SSH"
```

---

### Task 4: Create the Gitea wrapper Helm chart

**Files:**
- Create: `cluster/apps/gitea/Chart.yaml`
- Create: `cluster/apps/gitea/config.json`
- Create: `cluster/apps/gitea/values.yaml`

**Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: gitea
version: 0.1.0
dependencies:
  - name: gitea
    version: "12.5.0"
    repository: https://dl.gitea.com/charts/
```

**Step 2: Create config.json**

```json
{"appName": "gitea", "namespace": "gitea", "chartPath": "cluster/apps/gitea"}
```

**Step 3: Create values.yaml**

This is the most complex file. All values nested under `gitea:` (the dependency name).

```yaml
gitea:
  # -- Disable bundled databases (using external PostgreSQL)
  postgresql-ha:
    enabled: false
  postgresql:
    enabled: false

  # -- Valkey standalone for cache and session storage
  valkey-cluster:
    enabled: false
  valkey:
    enabled: true
    architecture: standalone
    global:
      valkey:
        password: ""
    master:
      persistence:
        size: 1Gi

  # -- Persistence: use restored Longhorn volume
  persistence:
    enabled: true
    create: false
    mount: true
    claimName: gitea-shared-storage

  # -- SSH service: dedicated LoadBalancer via Cilium
  service:
    ssh:
      type: LoadBalancer
      port: 22
      loadBalancerClass: io.cilium/l2-announcer
      labels:
        app.kubernetes.io/part-of: gitea

  # -- Admin user from secret
  gitea:
    admin:
      existingSecret: gitea-admin-secret

    # -- GitHub OAuth2
    oauth:
      - name: GitHub
        provider: github
        existingSecret: gitea-oauth-secret

    # -- app.ini configuration (non-sensitive values)
    config:
      server:
        DOMAIN: gitea.xmple.io
        ROOT_URL: https://gitea.xmple.io/
        SSH_DOMAIN: ssh.gitea.xmple.io
        SSH_PORT: 22
        SSH_LISTEN_PORT: 2222
      database:
        DB_TYPE: postgres
      service:
        DISABLE_REGISTRATION: true
      migrations:
        ALLOWED_DOMAINS: "github.com,*.github.com"
      oauth2:
        ACCOUNT_LINKING: login
      actions:
        ENABLED: true
        DEFAULT_ACTIONS_URL: github
      storage:
        STORAGE_TYPE: minio
        MINIO_ENDPOINT: s3.xmple.io:9001
      mailer:
        ENABLED: true
        SMTP_ADDR: smtp.mail.me.com
        SMTP_PORT: 587
        PROTOCOL: smtp+starttls
        FROM: '"Gitea" <noreply@xmple.io>'
      ssh.minimum_key_sizes:
        RSA: 2048

    # -- Inject sensitive app.ini values from secret
    additionalConfigSources:
      - secret:
          secretName: gitea-config-secrets
```

**Important notes on values nesting:** The wrapper chart's dependency is named `gitea`, so all values go under `gitea:`. But the Gitea Helm chart itself has a `gitea:` key for its own config. This creates `gitea.gitea.config` in the wrapper — the first `gitea` is the dependency scope, the second is the chart's own key. The sub-charts (`postgresql-ha`, `valkey`, etc.) are also scoped under the outer `gitea:`.

**Step 4: Build dependencies to verify chart resolves**

Run: `helm repo add gitea https://dl.gitea.com/charts/ --force-update && helm dependency build cluster/apps/gitea`
Expected: `Saving 1 charts` ... `Deleting outdated charts`

**Step 5: Dry-run template to verify**

Run: `helm template gitea cluster/apps/gitea --namespace gitea 2>&1 | head -50`
Expected: Renders Kubernetes manifests without errors.

**Step 6: Commit**

```bash
git add cluster/apps/gitea/Chart.yaml cluster/apps/gitea/config.json cluster/apps/gitea/values.yaml
git commit -m "Add Gitea wrapper Helm chart with config"
```

---

### Task 5: Create PV and PVC templates for the restored Longhorn volume

**Files:**
- Create: `cluster/apps/gitea/templates/pv.yaml`

**Step 1: Create the PV and PVC**

The Longhorn volume `gitea-shared-storage` already exists (restored from backup). We need a PV that binds to it and a PVC that the Gitea deployment mounts.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: gitea-shared-storage
spec:
  capacity:
    storage: 20Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: gitea-shared-storage
    volumeAttributes:
      numberOfReplicas: "1"
      staleReplicaTimeout: "30"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitea-shared-storage
  namespace: gitea
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
  volumeName: gitea-shared-storage
```

**Note:** The `volumeHandle` must match the Longhorn volume name exactly: `gitea-shared-storage`. The `storageClassName` must be `longhorn` (the default Longhorn StorageClass). The PVC name must match `persistence.claimName` in values.yaml.

**Step 2: Verify template renders**

Run: `helm template gitea cluster/apps/gitea --namespace gitea 2>&1 | grep -A 20 'kind: PersistentVolume'`
Expected: Both PV and PVC rendered with correct names.

**Step 3: Commit**

```bash
git add cluster/apps/gitea/templates/pv.yaml
git commit -m "Add PV/PVC templates for restored Gitea Longhorn volume"
```

---

### Task 6: Create HTTPRoute template

**Files:**
- Create: `cluster/apps/gitea/templates/httproute.yaml`

**Step 1: Create the HTTPRoute**

Follow the exact pattern from `cluster/apps/argocd/templates/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: gitea
  namespace: gitea
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: traefik-gateway
      namespace: traefik
  hostnames:
    - gitea.xmple.io
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - group: ""
          kind: Service
          name: gitea-http
          port: 3000
          weight: 1
```

**Important:** The backend service name is `gitea-http` (the Gitea Helm chart creates services named `<release>-http` and `<release>-ssh`). Port 3000 is the HTTP service port. All explicit defaults (group, kind, weight, path type) must be specified to prevent ArgoCD drift.

**Step 2: Verify template renders**

Run: `helm template gitea cluster/apps/gitea --namespace gitea 2>&1 | grep -A 20 'kind: HTTPRoute'`
Expected: HTTPRoute with correct hostname, service name, port.

**Step 3: Commit**

```bash
git add cluster/apps/gitea/templates/httproute.yaml
git commit -m "Add HTTPRoute for Gitea HTTPS access"
```

---

### Task 7: Populate vars.yaml and run gitea-secrets task

**Files:**
- Modify: `vars.yaml` (git-ignored — add actual secret values)

**Step 1: Add Gitea section to vars.yaml**

The user adds the real values. Example structure:

```yaml
# Gitea
gitea_postgres_host: "10.1.1.x"
gitea_postgres_db: "gitea"
gitea_postgres_user: "gitea"
gitea_postgres_password: "<real password>"
gitea_admin_user: "admin"
gitea_admin_password: "<real password>"
gitea_admin_email: "admin@xmple.io"
gitea_oauth_client_id: "<github client id>"
gitea_oauth_client_secret: "<github client secret>"
gitea_smtp_user: "<smtp user>"
gitea_smtp_password: "<smtp password>"
gitea_minio_access_key: "<minio key>"
gitea_minio_secret_key: "<minio secret>"
gitea_secret_key: "<gitea internal secret key>"
gitea_ssh_ip: "10.1.1.62"
```

**Step 2: Run the secrets task**

Run: `task components:gitea-secrets`
Expected: Namespace `gitea` created, three secrets created (`gitea-admin-secret`, `gitea-oauth-secret`, `gitea-config-secrets`).

**Step 3: Verify secrets exist**

Run: `kubectl get secrets -n gitea`
Expected: All three secrets listed.

---

### Task 8: Push to git and verify ArgoCD sync

**Step 1: Push all commits to main**

Run: `git push origin main`

**Step 2: Watch ArgoCD discover the app**

Run: `kubectl get applications -n argocd`
Expected: `gitea` application appears (may take up to 3 minutes for ArgoCD to poll).

**Step 3: Monitor sync progress**

Run: `kubectl get application gitea -n argocd -w`
Expected: Status progresses from `OutOfSync` → `Synced`, Health from `Missing` → `Progressing` → `Healthy`.

If sync fails, check:
- `kubectl describe application gitea -n argocd` for sync errors
- `kubectl get events -n gitea` for pod/PVC issues
- `kubectl logs -n gitea -l app.kubernetes.io/name=gitea` for app startup errors

**Step 4: Verify Gitea pod is running**

Run: `kubectl get pods -n gitea`
Expected: Gitea pod running, Valkey pod running.

---

### Task 9: Verify the migration

**Step 1: Check web UI**

Open: `https://gitea.xmple.io` in a browser
Expected: Gitea login page loads. Existing repos visible after login.

**Step 2: Verify HTTPS git access**

Run: `git ls-remote https://gitea.xmple.io/<user>/<repo>.git`
Expected: Lists refs from a known repository.

**Step 3: Verify SSH git access**

Run: `ssh -T git@ssh.gitea.xmple.io` (or the configured SSH hostname)
Expected: Gitea welcome message.

Run: `git ls-remote git@ssh.gitea.xmple.io:<user>/<repo>.git`
Expected: Lists refs.

**Step 4: Verify OAuth login**

Click "Sign in with GitHub" on the login page.
Expected: Redirects to GitHub, completes OAuth flow, returns to Gitea.

**Step 5: Verify Actions**

Navigate to a repo with Actions configured.
Expected: Actions tab shows, workflows can be triggered.

**Step 6: Test push/pull**

Clone a repo, make a change, push.
Expected: Push succeeds over both HTTPS and SSH.
