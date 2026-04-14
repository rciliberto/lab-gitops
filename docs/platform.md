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
- Launch apps: `launch-<app>` (e.g., `launch-onedev`)

## Adding an App

Create a directory under the appropriate category:

```sh
mkdir -p apps/lab/my-app/templates
```

Add `Chart.yaml`, `values.yaml`, and `templates/namespace.yaml` at minimum. Commit and push — ArgoCD discovers and syncs automatically. No config files to update.

## Fresh Cluster Bootstrap

1. Install ArgoCD:
   ```sh
   helm install argocd argo-cd --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace
   ```
2. Apply the root ApplicationSet:
   ```sh
   kubectl apply -f bootstrap/applicationset.yaml
   ```
3. ArgoCD syncs `platform/*` — creates AppProjects, ApplicationSets, and its own full config.
4. ApplicationSets discover and sync all apps from `apps/core/*`, `apps/lab/*`, `apps/tenants/*`, `apps/launch/*`.

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
