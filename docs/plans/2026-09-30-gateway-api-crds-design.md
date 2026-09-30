# Gateway API CRDs as an ArgoCD-managed app

## Problem

Nothing in git owned the Gateway API CRDs.

- The Traefik chart shipped the standard-channel CRDs in its `crds/` directory until 40.2.0, which removed them ([traefik-helm-chart#1669](https://github.com/traefik/traefik-helm-chart/issues/1669)). Its README now says to `kubectl apply` the upstream bundle by hand. The separate `traefik-crds` chart is deprecated and frozen at 1.18.0 (Gateway API v1.5.1).
- `task components:traefik` applied `experimental-install.yaml` v1.4.0 from a hard-coded URL that no tool tracked.

The live cluster was left with a mix: eight standard-channel CRDs at v1.5.1 from the last Traefik chart that carried them, and `tcproutes`, `udproutes` and three `x-k8s.io` CRDs at experimental v1.4.0 from the bootstrap task. A fresh bootstrap would have installed v1.4.0 throughout.

## Constraints

- **Experimental channel.** Gitea SSH is a `TCPRoute`. Traefik 3.7 watches `TCPRoute` as `v1alpha2`; from Gateway API v1.6 the standard channel serves only `v1`. With `providers.kubernetesGateway.experimentalChannel: true` and a version Traefik cannot watch, the Gateway provider never finishes starting and serves no routes at all, without logging an error. Traefik 3.8 is due to move to `v1` and drop this requirement.
- **Traefik sets the pace.** Traefik 3.7.10+ supports Gateway API v1.6.1 and remains compatible with v1.5.x. The CRD version must not run ahead of what the deployed Traefik supports.
- **Wrapper chart pattern.** Every app under `cluster/apps/` is a Helm chart that CI lints and Renovate tracks through `Chart.yaml`.

## Options considered

| Option | Verdict |
|---|---|
| Traefik chart / `traefik-crds` | Not possible: removed and frozen upstream. |
| Upstream Helm chart | Does not exist. `kubernetes-sigs/gateway-api` publishes only `standard-install.yaml` and `experimental-install.yaml`. |
| Kustomize app pointing at the upstream release URL | First-party source, but breaks the wrapper chart pattern, is skipped by CI's Helm validation, and needs a custom Renovate regex manager. |
| Vendoring the bundle into `templates/` | Renovate would bump a version string without changing the 1.4 MB of CRDs next to it. |
| Envoy Gateway's `gateway-crds-helm` | Versioned by Envoy Gateway releases, so the Gateway API version is not visible in `Chart.yaml`. |
| **`wiremind/gateway-api-crds`** | Chosen. |

## Design

`cluster/apps/gateway-api` wraps `gateway-api-crds` from `https://wiremind.github.io/wiremind-helm-charts`. The chart takes no values, its version equals the Gateway API bundle version, and it renders the experimental channel: 13 CRDs plus the `safe-upgrades` ValidatingAdmissionPolicy and its binding. At 1.6.2 the rendered CRD specs are identical to upstream's `experimental-install.yaml` v1.6.2.

- The app is listed in the `networking` group, destination namespace `kube-system` (every resource is cluster-scoped).
- `task components:gateway-api` renders the same chart and pipes it to `kubectl apply --server-side`, and `components:traefik` calls it first, so bootstrap and ArgoCD install one pinned version.
- Renovate tracks the dependency through its Helm manager with automerge off.

### Trade-offs

- The packager is a third party. Each bump is reviewed by hand, and the check in CLAUDE.md confirms the bundle still serves the versions Traefik watches.
- The chart lags upstream (1.6.2 appeared a week after the upstream release; 1.6.1 was never published).
- The Application carries the group's standard `resources-finalizer`, so deleting it deletes the CRDs and every Gateway API object. Remove the finalizer before removing the app.

## First rollout on the existing cluster

The `safe-upgrades` policy rejects experimental CRDs applied over standard ones, and eight live CRDs are standard-channel. The policy does not exist in the cluster yet, so the CRDs are moved to the experimental channel before ArgoCD creates it:

1. Before merging, apply only the CRDs, under ArgoCD's field manager:
   `helm template gateway-api cluster/apps/gateway-api | yq 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --force-conflicts --field-manager=argocd-controller -f -`
2. Compare each live CRD's `.spec` with the rendered one. The live CRDs carry two older apply managers, `kubectl` (the v1.4.0 bundle) and `helm` (the Traefik chart's v1.5.1 CRDs). Server-side apply only takes over fields the new bundle sets, so anything those managers own that v1.6.2 omits stays behind. If a spec differs, re-apply the same CRDs once with `--field-manager=kubectl` and once with `--field-manager=helm`, which resets each manager to exactly the new bundle and drops its leftovers, then once more as `argocd-controller`.
3. Confirm Traefik still serves: `kubectl get httproute -A`, an HTTPS request through `10.1.1.60`, and `ssh -T git@<gitea host>` for the TCPRoute (the `gitea-ssh` entrypoint is exposed on port 22).
4. Confirm the `traefik` Application does not track any Gateway API CRD, so two Applications never contend for them: `kubectl get application traefik -n argocd -o json | jq '.status.resources[] | select(.kind == "CustomResourceDefinition" and (.name | test("gateway.networking")))'` must be empty.
5. Merge. ArgoCD creates the `gateway-api` Application, adopts the CRDs and adds the policy.
6. Delete the leftover `xlistenersets.gateway.networking.x-k8s.io` CRD (v1.4.0, replaced by `listenersets`, no objects).

If the policy is ever created first and blocks a sync, delete the `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy and its binding, sync, and let ArgoCD recreate them.
