# Taskfile Split Design

## Goal

Break the monolithic `Taskfile.yaml` (~360 lines, ~20 tasks) into domain-grouped files under `taskfiles/` for easier navigation, separation of concerns, and future growth.

## File Layout

```
Taskfile.yaml                     # Entry point: vars, helpers, includes, top-level wrappers
taskfiles/
  setup.yaml                      # Initial cluster provisioning
  components.yaml                 # Helm component installs
  day2.yaml                       # Ongoing operations
  utility.yaml                    # Diagnostics and inspection
```

## Root Taskfile.yaml

Thin entry point containing:

- **Global vars** (14 `yq` calls from `vars.yaml`) — inherited by all included files automatically
- **Internal helpers** (`_require-node-ip`, `_require-helm`) — called from included files via `:_require-node-ip`
- **`set-node`** — used by the `setup` wrapper and useful standalone
- **`setup`** wrapper — full bootstrap sequence calling tasks across namespaces
- **`reconfigure`** wrapper — re-patch and apply config
- **4 namespaced includes** (no `flatten`)

```yaml
includes:
  setup:
    taskfile: ./taskfiles/setup.yaml
  components:
    taskfile: ./taskfiles/components.yaml
  day2:
    taskfile: ./taskfiles/day2.yaml
  utility:
    taskfile: ./taskfiles/utility.yaml
```

## Task Assignment

| File | Tasks |
|---|---|
| `Taskfile.yaml` | `_require-node-ip`, `_require-helm`, `set-node`, `setup`, `reconfigure` |
| `taskfiles/setup.yaml` | `download`, `generate`, `patch`, `apply`, `bootstrap`, `kubeconfig` |
| `taskfiles/components.yaml` | `cilium`, `traefik`, `cert-manager`, `longhorn-secret`, `longhorn`, `argocd` |
| `taskfiles/day2.yaml` | `upgrade-talos`, `upgrade-k8s`, `reboot`, `reset` |
| `taskfiles/utility.yaml` | `status`, `dashboard`, `disks`, `links` |

Note: `reconfigure` moves from the day-2 group to a top-level wrapper in root. The `setup` orchestration task also lives in root since it calls tasks across all namespaces.

## Cross-File References

Taskfile's `includes:` with namespacing requires explicit references for cross-domain calls:

- **Included files calling root helpers:** `:_require-node-ip`, `:_require-helm`
- **Root `setup` wrapper calling included tasks:** `:setup:generate`, `:setup:patch`, `:components:cilium`, etc.
- **Root `reconfigure` wrapper:** calls `:setup:patch` then runs `talosctl apply-config`

## Command Reference

```
task setup                        # Full bootstrap (root wrapper)
task reconfigure                  # Re-patch and apply config (root wrapper)
task set-node NODE_IP=x.x.x.x    # Save node IP

task setup:download               # Download Talos ISO
task setup:generate               # Generate Talos configs
task setup:apply                  # Apply config to node (insecure, first install)
task setup:kubeconfig             # Retrieve kubeconfig

task components:cilium            # Install/upgrade Cilium
task components:traefik           # Install/upgrade Traefik
task components:cert-manager      # Install/upgrade cert-manager
task components:longhorn-secret   # Create Longhorn namespace + S3 secret
task components:longhorn          # Install/upgrade Longhorn (manual)
task components:argocd            # Install/upgrade ArgoCD

task day2:upgrade-talos           # Upgrade Talos OS
task day2:upgrade-k8s             # Upgrade Kubernetes
task day2:reboot                  # Reboot node
task day2:reset                   # Wipe node (destructive)

task utility:status               # Cluster health check
task utility:dashboard            # Talos dashboard
task utility:disks                # List node disks
task utility:links                # List network interfaces
```

## Design Decisions

**Namespaced includes (no flatten):** Makes domain grouping visible at the command level and improves discoverability via `task --list`. Trade-off: slightly longer commands, but clearer intent.

**Top-level wrappers for `setup` and `reconfigure`:** These are the most frequently used multi-step commands. Keeping them at root avoids `setup:setup` collision and gives `reconfigure` a short path despite being a cross-domain operation.

**Vars and helpers stay in root:** Taskfile's include system propagates root-level vars to all included files. Internal helpers are shared across domains, so centralizing them avoids duplication.

**`reconfigure` at root, not in day2:** It's a common operation that calls `:setup:patch` (cross-domain) and deserves a short command path.
