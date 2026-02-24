# Secrets Management

Secrets are stored in `vars.yaml` (git-ignored) and injected into the cluster via Taskfile tasks. All secret creation commands use `--dry-run=client -o yaml | kubectl apply -f -` for idempotency — safe to re-run at any time.

## How It Works

```
vars.yaml (git-ignored)  ──→  Taskfile extracts via yq  ──→  kubectl create secret
local key files (.pem, ssh keys)  ──────────────────────────→  kubectl --from-file
```

**Bootstrap secrets** (cert-manager, ArgoCD) are created during `task setup` before ArgoCD is running.

**Post-bootstrap secrets** (Longhorn, db3000, Gitea, Renovate) are created after ArgoCD has synced and created the target namespaces via `CreateNamespace=true`. Wait for the namespace to exist before running the secret task.

## Setup Checklist

1. Copy `vars.yaml.example` to `vars.yaml`
2. Fill in all secret values
3. Generate required key files (see per-component sections below)
4. Run `task setup` for the full bootstrap, or individual `task components:*` tasks

---

## cert-manager

**Secret:** `cloudflare-api-token` in `cert-manager` namespace

**Purpose:** Cloudflare API token for DNS-01 ACME challenges (wildcard TLS certificates).

**Setup:**
1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens) → Create Token
2. Use the "Edit zone DNS" template, scope to your zone
3. Add to `vars.yaml`:
   ```yaml
   cloudflare_api_token: "your-cloudflare-api-token"
   ```

**Created by:** `task components:cert-manager` (bundled with the Helm install)

**Secret contents:**
| Key | Value |
|-----|-------|
| `api-token` | Cloudflare API token |

---

## Longhorn

**Secret:** `longhorn-s3-secret` in `longhorn-system` namespace

**Purpose:** S3-compatible credentials for Longhorn volume backups (e.g., MinIO on TrueNAS).

**Setup:**
1. Create an S3 bucket and access credentials on your storage backend
2. Add to `vars.yaml`:
   ```yaml
   longhorn_s3_endpoint: "https://truenas.local:9000"
   longhorn_s3_access_key: "your-minio-access-key"
   longhorn_s3_secret_key: "your-minio-secret-key"
   ```

**Created by:** `task components:longhorn-secret` (run after ArgoCD creates `longhorn-system` namespace)

**Secret contents:**
| Key | Value |
|-----|-------|
| `AWS_ACCESS_KEY_ID` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | S3 secret key |
| `AWS_ENDPOINTS` | S3 endpoint URL |

---

## ArgoCD

### Repository Deploy Key

**Secret:** `argocd-repo-key` in `argocd` namespace

**Purpose:** SSH deploy key for ArgoCD to read this git repository.

**Setup:**
1. Generate an Ed25519 key pair:
   ```bash
   ssh-keygen -t ed25519 -f argocd-repo-key -N ""
   ```
2. Add `argocd-repo-key.pub` as a **read-only deploy key** in GitHub repo settings:
   GitHub → repo → Settings → Deploy keys → Add deploy key

**Created by:** `task components:argocd` (bundled with the Helm install)

**Secret contents:**
| Key | Value |
|-----|-------|
| `type` | `git` |
| `url` | `git@github.com:msnelling/talos-cluster.git` |
| `sshPrivateKey` | Contents of `argocd-repo-key` file |

The secret is also labelled `argocd.argoproj.io/secret-type=repository` so ArgoCD auto-discovers it.

### GitHub OAuth (Dex)

**Secret:** `argocd-secret` in `argocd` namespace (extra fields injected via `helm --set`)

**Purpose:** GitHub OAuth client credentials for ArgoCD login via Dex.

**Setup:**
1. Go to GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
2. Set callback URL to `https://argocd.yourdomain.com/api/dex/callback`
3. Note the Client ID and generate a Client Secret
4. Add to `vars.yaml`:
   ```yaml
   github_oauth_client_id: "your-client-id"
   github_oauth_client_secret: "your-client-secret"
   ```

**Created by:** `task components:argocd` (injected via `helm --set` during install)

**Injection method:** Unlike other secrets, these are injected directly into the Helm release via `--set` flags, not created as a standalone secret. ArgoCD's chart stores them in the `argocd-secret` Secret automatically.

---

## db3000 Media Apps

All db3000 secrets are created by a single task: `task components:db3000-secrets`. Run after ArgoCD creates the `db3000` namespace.

### SMB Credentials

**Secret:** `media-smb-creds` in `db3000` namespace

**Purpose:** NAS SMB share credentials for media storage mounts.

**vars.yaml:**
```yaml
smb_username: "your-smb-username"
smb_password: "your-smb-password"
```

**Secret contents:**
| Key | Value |
|-----|-------|
| `username` | SMB username |
| `password` | SMB password |

### VPN (Gluetun/Transmission)

**Secret:** `transmission-vpn-secrets` in `db3000` namespace

**Purpose:** WireGuard VPN credentials for the Gluetun sidecar on Transmission.

**vars.yaml:**
```yaml
vpn_service_provider: "mullvad"
vpn_type: "wireguard"
vpn_wireguard_private_key: "your-wireguard-private-key"
vpn_wireguard_addresses: "your-wireguard-addresses"
vpn_server_cities: "your-server-cities"
```

**Secret contents:**
| Key | Value |
|-----|-------|
| `VPN_SERVICE_PROVIDER` | e.g., `mullvad` |
| `VPN_TYPE` | e.g., `wireguard` |
| `WIREGUARD_PRIVATE_KEY` | WireGuard private key |
| `WIREGUARD_ADDRESSES` | WireGuard addresses |
| `SERVER_CITIES` | Preferred server cities |

### HTTP Proxy Credentials

**Secret:** `transmission-proxy-credentials` in `db3000` namespace

**Purpose:** HTTP proxy credentials exposed by Gluetun for other containers.

**vars.yaml:**
```yaml
vpn_proxy_user: "your-proxy-user"
vpn_proxy_password: "your-proxy-password"
```

**Secret contents:**
| Key | Value |
|-----|-------|
| `HTTPPROXY_USER` | Proxy username |
| `HTTPPROXY_PASSWORD` | Proxy password |

### Gluetun Auth Config

**Secret:** `gluetun-auth-secrets` in `db3000` namespace

**Purpose:** Gluetun authentication configuration (TOML format).

**vars.yaml:**
```yaml
vpn_auth_config: |
  # TOML config content
```

**Injection method:** The TOML content is extracted from `vars.yaml` via `yq` and piped as a file:
```bash
yq -r '.vpn_auth_config' vars.yaml | kubectl create secret generic gluetun-auth-secrets \
  --from-file=config.toml=/dev/stdin ...
```

**Secret contents:**
| Key | Value |
|-----|-------|
| `config.toml` | Gluetun auth TOML config |

---

## Gitea

All Gitea secrets are created by: `task components:gitea-secrets`. Run after ArgoCD creates the `gitea` namespace.

### Admin Credentials

**Secret:** `gitea-admin-secret` in `gitea` namespace

**Purpose:** Initial Gitea admin account credentials.

**vars.yaml:**
```yaml
gitea_admin_user: "admin"
gitea_admin_password: "your-admin-password"
gitea_admin_email: "admin@example.com"
```

**Secret contents:**
| Key | Value |
|-----|-------|
| `username` | Admin username |
| `password` | Admin password |
| `email` | Admin email |

### Application Config

**Secret:** `gitea-config-secrets` in `gitea` namespace

**Purpose:** Gitea database, security, mailer, and storage configuration. Each key contains a multi-line INI-style string of key-value pairs.

**vars.yaml:**
```yaml
gitea_postgres_host: "truenas.local"
gitea_postgres_db: "gitea"
gitea_postgres_user: "gitea"
gitea_postgres_password: "your-db-password"
gitea_secret_key: "your-gitea-secret-key"
gitea_smtp_user: "your-smtp-username"
gitea_smtp_password: "your-smtp-password"
gitea_minio_access_key: "your-minio-access-key"
gitea_minio_secret_key: "your-minio-secret-key"
```

**Secret contents:**
| Key | Value format |
|-----|-------------|
| `database` | `HOST=...\nNAME=...\nUSER=...\nPASSWD=...` |
| `security` | `SECRET_KEY=...` |
| `mailer` | `USER=...\nPASSWD=...` |
| `storage` | `MINIO_ACCESS_KEY_ID=...\nMINIO_SECRET_ACCESS_KEY=...` |

---

## Renovate

**Secret:** `renovate-token` in `renovate` namespace

**Purpose:** GitHub App credentials for the self-hosted Renovate CronJob. Renovate uses these to generate short-lived installation tokens before each run.

**Setup:**
1. Go to GitHub → Settings → Developer settings → GitHub Apps → New GitHub App
2. Configure the app:
   - **Name:** e.g., "Renovate Bot"
   - **Homepage URL:** any valid URL
   - **Webhook:** uncheck "Active" (not needed — Renovate is cron-driven)
   - **Permissions:**
     - Contents: Read & write
     - Issues: Read & write
     - Pull requests: Read & write
     - Metadata: Read-only
3. Create the app and note the **App ID** (numeric, shown at top of app settings page — not the Client ID which starts with `Iv1.`)
4. Generate a private key → downloads as a `.pem` file
5. Rename it to `renovate-app-key.pem` and place it in the repo root
6. Install the app: GitHub → Settings → Developer settings → GitHub Apps → your app → Install App → select your account → choose "All repositories" or select specific repos
7. Add to `vars.yaml`:
   ```yaml
   renovate_github_app_id: "888069"  # Your numeric App ID
   ```

**Created by:** `task components:renovate-secret` (run after ArgoCD creates `renovate` namespace)

**Secret contents:**
| Key | Value |
|-----|-------|
| `RENOVATE_GITHUB_APP_ID` | Numeric App ID |
| `RENOVATE_GITHUB_APP_KEY` | PEM private key file contents |

**How authentication works:** The Renovate CronJob runs a `preCommand` script before each execution that:
1. Creates a JWT from the App ID + PEM key using `openssl`
2. Calls `GET /app/installations` to find the installation ID
3. Calls `POST /app/installations/{id}/access_tokens` to get a short-lived token
4. Exports it as `RENOVATE_TOKEN` for the Renovate process

This generates a fresh token every run — no expiry management needed.

---

## Key Files (git-ignored)

| File | Purpose | Generated by |
|------|---------|-------------|
| `vars.yaml` | All secret values | Copy from `vars.yaml.example` |
| `argocd-repo-key` | SSH private key for ArgoCD | `ssh-keygen -t ed25519 -f argocd-repo-key -N ""` |
| `argocd-repo-key.pub` | SSH public key (add to GitHub deploy keys) | Generated alongside private key |
| `renovate-app-key.pem` | GitHub App private key for Renovate | Downloaded from GitHub App settings |

## Re-creating Secrets

All secret tasks are idempotent. To update a secret value:

1. Update `vars.yaml` (or replace the key file)
2. Re-run the relevant `task components:*` task
3. Restart pods that use the secret (CronJobs pick it up on next run automatically)
