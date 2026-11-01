# Platform Architecture

## ArgoCD Projects

| Project | Source Path | Allowed Namespaces | Cluster-Scoped Resources |
|---------|------------|-------------------|------------------------|
| `platform` | `platform/*` | Any | Yes |
| `core` | `apps/core/*` | Any | Yes |
| `lab` | `apps/lab/*` | Any (convention: no `tenant-*` or `launch-*`) | No |
| `tenants` | `apps/tenants/*` | `tenant-*` only | No |
| `launch` | `apps/launch/*` | `launch-*` only | No |

## Namespace Conventions

- Namespace = directory name for all apps
- Personal apps: natural names (e.g., `actual-budget`)
- Tenant apps: `tenant-<person>-<app>` (e.g., `tenant-dchen-actual-budget`)
- Launch apps: `launch-<app>` (e.g., `launch-forgejo`)

## Router BGP

Cilium's BGP control plane peers with the UniFi Dream Machine Pro at `10.20.20.1` from every node (`apps/core/cilium/templates/ciliumbgp*.yaml`):

- UniFi/router ASN: `64501`
- Kubernetes/Cilium ASN: `64500`
- LoadBalancer pool (`CiliumLoadBalancerIPPool`): `10.30.0.2-10.30.0.255`
- Imported route filter: `10.30.0.0/24 le 32`

Upload [unifi-metallb-bgp.conf](unifi-metallb-bgp.conf) in UniFi Network under Dynamic Routing > BGP. It was written for MetalLB, but the ASNs, neighbors and prefixes are the same. The config accepts only LoadBalancer service routes and advertises no routes back to the cluster.

## Adding an App

Create a directory under the appropriate category:

```sh
mkdir -p apps/lab/my-app/templates
```

Add `Chart.yaml`, `values.yaml`, and `templates/namespace.yaml` at minimum. Commit and push — ArgoCD discovers and syncs automatically. No config files to update.

Put each Kubernetes resource in its own file under `templates/`, named after its kind in lowercase (`namespace.yaml`, `pvc.yaml`, `deployment.yaml`, `service.yaml`, `httproute.yaml`, `sealed-secrets.yaml`). When an app has more than one resource of a kind, add a suffix that says which one, such as `httproute-public.yaml`, `deployment-ci.yaml` or `sealed-secrets-redis.yaml`. Wrap a resource that a value toggles in its own `{{- if }}` inside its file.

## Fresh Cluster Bootstrap

1. Install Cilium (ArgoCD needs a CNI to run; ArgoCD adopts this release later):
   ```sh
   helm dependency build apps/core/cilium
   helm install cilium apps/core/cilium -n cilium --create-namespace
   ```
   The BGP and LoadBalancer pool resources need CRDs that the Cilium operator creates on startup, so remove `templates/cilium*.yaml` for this first install (or re-run it once the operator is up); ArgoCD applies them later.
2. Install ArgoCD:
   ```sh
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace
   ```
3. Apply the root ApplicationSet:
   ```sh
   kubectl apply -f bootstrap/applicationset.yaml
   ```
4. ArgoCD syncs `platform/*` — creates AppProjects, ApplicationSets, and its own full config.
5. ApplicationSets discover and sync all apps from `apps/core/*`, `apps/lab/*`, `apps/tenants/*`, `apps/launch/*`.

## Migration from Single ApplicationSet

If migrating from the previous flat `apps/*/config.json` setup:

1. Merge the restructured repo to `main`.
2. Delete the old ApplicationSet, preserving running Applications:
   ```sh
   kubectl delete applicationset lab-apps -n argocd --cascade=false
   ```
3. Apply the new root ApplicationSet:
   ```sh
   kubectl apply -f bootstrap/applicationset.yaml
   ```
4. Wait for platform to sync — AppProjects and new ApplicationSets are created.
5. New ApplicationSets create Applications at the new paths, replacing orphaned ones.
6. Verify all Applications are healthy in the ArgoCD UI.

**Rollback:** Re-apply the old `bootstrap/applicationset.yaml` from git history. Orphaned Applications continue running regardless.
