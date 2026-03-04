# Gitea Runner Design

## Overview

Deploy the Gitea Act Runner as a wrapper Helm chart to enable CI/CD workflows in Gitea Actions. The runner uses Docker-in-Docker (DinD) for container isolation and registers as an instance-level runner.

## Architecture

### Chart Structure

```
cluster/apps/gitea-runner/
  Chart.yaml          # Wraps gitea-charts/actions v0.0.3
  values.yaml         # Config nested under actions: key
  templates/
    namespace.yaml    # gitea-runner namespace with privileged PodSecurity
```

### Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Execution mode | Docker-in-Docker | Container isolation for each job; full GitHub Actions compatibility |
| Namespace | `gitea-runner` (dedicated) | DinD requires privileged PodSecurity; isolate from Gitea's baseline namespace |
| Runner scope | Instance-level | Available to all repos; simplest setup for homelab |
| Replicas | 1 | Sufficient for homelab CI load; jobs still run as separate DinD containers |
| Gitea URL | `http://gitea-http.gitea.svc.cluster.local:3000` | Internal service URL; no TLS overhead, no ingress dependency |
| Token management | Manual from Gitea admin UI | One-time setup; token stored in vars.yaml, secret created via Taskfile |

### Namespace

The `gitea-runner` namespace requires a `privileged` PodSecurity label because DinD runs with `privileged: true` security context. The namespace is created by a chart template (not ArgoCD `CreateNamespace`) to ensure the PodSecurity label is applied.

### Registration Flow

1. User copies instance-level registration token from Gitea admin UI (`/-/admin/actions/runners`)
2. Token added to `vars.yaml` as `GITEA_RUNNER_TOKEN`
3. `task components:runner-token` creates the `runner-token` secret in `gitea-runner` namespace
4. Chart references `existingSecret: runner-token` — the init container uses it to register on first boot
5. Registration state is persisted in the StatefulSet's PVC; token not needed again after initial registration

### Runner Configuration

```yaml
actions:
  enabled: true
  giteaRootURL: "http://gitea-http.gitea.svc.cluster.local:3000"
  existingSecret: "runner-token"
  existingSecretKey: "token"

  statefulset:
    replicas: 1
    actRunner:
      config: |
        log:
          level: info
        cache:
          enabled: false
        container:
          require_docker: true
          docker_timeout: 300s
    dind: {}  # defaults: docker:28.3.3-dind
    persistence:
      size: 1Gi
```

### ArgoCD Integration

- Added to the `services` group in `cluster/groups/services/values.yaml`
- Auto-sync with self-heal and prune enabled (standard policy)
- Namespace created by chart template with PodSecurity labels

### Secret

| Secret | Namespace | Source |
|---|---|---|
| `runner-token` | gitea-runner | `task components:runner-token` (from vars.yaml `GITEA_RUNNER_TOKEN`) |

Created via heredoc + `stringData` pattern, consistent with other secret tasks.

### Networking

The runner communicates with Gitea via the internal Kubernetes service URL. No HTTPRoute or external exposure needed — the runner is a consumer, not a service.

```
act-runner pod (gitea-runner ns) → gitea-http.gitea.svc.cluster.local:3000 → Gitea pod (gitea ns)
```

## Files to Create/Modify

| File | Action | Purpose |
|---|---|---|
| `cluster/apps/gitea-runner/Chart.yaml` | Create | Wrapper chart declaring gitea-charts/actions as dependency |
| `cluster/apps/gitea-runner/values.yaml` | Create | Runner configuration (DinD, internal URL, secret ref) |
| `cluster/apps/gitea-runner/templates/namespace.yaml` | Create | Namespace with privileged PodSecurity label |
| `cluster/groups/services/values.yaml` | Modify | Add gitea-runner entry to services group |
| `taskfiles/components.yaml` | Modify | Add runner-token secret task |
| `vars.yaml.example` | Modify | Document GITEA_RUNNER_TOKEN variable |

## Post-Deploy Steps

1. Push changes to git (ArgoCD syncs from remote)
2. Wait for ArgoCD to create the `gitea-runner` namespace
3. Get registration token from Gitea admin UI
4. Add token to `vars.yaml`
5. Run `task components:runner-token`
6. Runner pod starts, registers with Gitea, and becomes available for workflows
