# ArgoCD GitHub OAuth Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub OAuth authentication via Dex and rename ArgoCD URL from argocd-beta.xmple.io to argocd.xmple.io.

**Architecture:** Dex (built into ArgoCD chart) bridges GitHub OAuth 2.0 to OIDC. The `orgs` filter restricts login to `xmple` org members. All authenticated users get admin via `policy.default: role:admin`. The clientSecret is injected at install time via Helm `--set`, matching existing secret patterns.

**Tech Stack:** argo-cd Helm chart v9.4.2, Dex GitHub connector, Taskfile vars

**Design doc:** `docs/plans/2026-02-24-argocd-github-oauth-design.md`

---

### Task 1: Rename ArgoCD URL in HTTPRoute

**Files:**
- Modify: `cluster/apps/argocd/templates/httproute.yaml:13`

**Step 1: Edit the hostname**

Change line 13 from:
```yaml
    - argocd-beta.xmple.io
```
to:
```yaml
    - argocd.xmple.io
```

**Step 2: Validate the template renders**

Run: `helm template argocd cluster/apps/argocd --namespace argocd 2>/dev/null | grep -A2 'hostnames:'`
Expected: output contains `- argocd.xmple.io` (not `argocd-beta`)

**Step 3: Commit**

```bash
git add cluster/apps/argocd/templates/httproute.yaml
git commit -m "feat(argocd): rename URL from argocd-beta to argocd.xmple.io"
```

---

### Task 2: Add Dex config, RBAC, and URL to ArgoCD values

**Files:**
- Modify: `cluster/apps/argocd/values.yaml`

**Step 1: Replace the full values.yaml**

The current file is 7 lines. Replace with:

```yaml
argo-cd:
  server:
    insecure: true

  configs:
    params:
      server.insecure: true

    cm:
      url: https://argocd.xmple.io
      dex.config: |
        connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: REPLACE_WITH_GITHUB_CLIENT_ID
              clientSecret: $dex.github.clientSecret
              orgs:
                - name: xmple

    rbac:
      policy.default: role:admin
      scopes: "[groups]"
```

Note: `REPLACE_WITH_GITHUB_CLIENT_ID` is a placeholder. The user must replace it with their actual GitHub OAuth App client ID after creating the app (Task 6). The clientID is not sensitive — it can be committed to git.

**Step 2: Validate the template renders the ConfigMap**

Run: `helm template argocd cluster/apps/argocd --namespace argocd 2>/dev/null | grep -A20 'kind: ConfigMap' | head -30`
Expected: output shows `argocd-cm` ConfigMap containing `url: https://argocd.xmple.io` and `dex.config`

**Step 3: Validate RBAC ConfigMap**

Run: `helm template argocd cluster/apps/argocd --namespace argocd 2>/dev/null | grep -A5 'policy.default'`
Expected: output contains `policy.default: role:admin`

**Step 4: Commit**

```bash
git add cluster/apps/argocd/values.yaml
git commit -m "feat(argocd): add Dex GitHub OAuth config, RBAC, and URL"
```

---

### Task 3: Add secret injection to Taskfile

**Files:**
- Modify: `Taskfile.yaml` (add vars at line ~53, after the Gitea vars block)
- Modify: `taskfiles/components.yaml:76-79` (add `--set` to helm command)

**Step 1: Add vars to root Taskfile.yaml**

After the `GITEA_SECRET_KEY` var block (line 78), add:

```yaml
  # ArgoCD GitHub OAuth
  GITHUB_OAUTH_CLIENT_SECRET:
    sh: yq '.github_oauth_client_secret' vars.yaml
```

Note: We only need the secret in vars. The clientID lives directly in `values.yaml`.

**Step 2: Add `--set` to the helm upgrade command in components.yaml**

The current helm command (lines 76-79) is:

```yaml
      - helm upgrade --install argocd cluster/apps/argocd
          --namespace argocd
          --force-conflicts
          --wait --timeout 5m
```

Change to:

```yaml
      - helm upgrade --install argocd cluster/apps/argocd
          --namespace argocd
          --set argo-cd.configs.secret.extra.dex\\.github\\.clientSecret={{.GITHUB_OAUTH_CLIENT_SECRET}}
          --force-conflicts
          --wait --timeout 5m
```

**Step 3: Commit**

```bash
git add Taskfile.yaml taskfiles/components.yaml
git commit -m "feat(argocd): inject GitHub OAuth clientSecret via Taskfile"
```

---

### Task 4: Update vars.yaml.example and CLAUDE.md

**Files:**
- Modify: `vars.yaml.example` (add new vars at end)
- Modify: `CLAUDE.md` (update secrets table)

**Step 1: Add vars to vars.yaml.example**

Append after the Gitea section (after line 51):

```yaml

# ArgoCD GitHub OAuth
github_oauth_client_secret: "your-github-oauth-client-secret"
```

**Step 2: Add secret to CLAUDE.md secrets table**

In the `## Secrets (Not in Git)` table, add a row after `argocd-repo-key`:

```
| `argocd-secret` (dex.github.clientSecret) | argocd | `task components:argocd` (from vars.yaml) |
```

**Step 3: Commit**

```bash
git add vars.yaml.example CLAUDE.md
git commit -m "docs: add GitHub OAuth vars and secrets documentation"
```

---

### Task 5: Validate full chart renders cleanly

**Step 1: Build dependencies and template the full chart**

Run: `helm dependency build cluster/apps/argocd && helm template argocd cluster/apps/argocd --namespace argocd > /dev/null`
Expected: exit code 0, no errors

**Step 2: Spot-check key resources**

Run: `helm template argocd cluster/apps/argocd --namespace argocd 2>/dev/null | grep -c 'kind:'`
Expected: a number (confirms multiple resources rendered)

---

### Task 6: Manual steps (user performs these)

These steps cannot be automated and must be done by the user:

1. **Create GitHub OAuth App** at `https://github.com/organizations/xmple/settings/applications`:
   - Homepage URL: `https://argocd.xmple.io`
   - Callback URL: `https://argocd.xmple.io/api/dex/callback`

2. **Update values.yaml** — replace `REPLACE_WITH_GITHUB_CLIENT_ID` with the actual client ID from the OAuth App

3. **Update vars.yaml** — add `github_oauth_client_secret` with the client secret from the OAuth App

4. **Create/update DNS** — ensure `argocd.xmple.io` resolves to `10.1.1.60`

5. **Deploy** — run `task components:argocd` or push to git and let ArgoCD sync

6. **Verify** — visit `https://argocd.xmple.io`, click "Log in via GitHub", authenticate with a GitHub account that's a member of the `xmple` org
