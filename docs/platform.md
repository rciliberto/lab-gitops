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

Cilium's BGP control plane peers with the UniFi Dream Machine Pro at `10.20.20.1` from every node (`apps/core/cilium/templates/bgp.yaml`):

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

## Postgres Backups

CNPG clusters back up with the [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) (installed with the operator in `cnpg-system`) to a [Garage](https://garagehq.deuxfleurs.fr/) S3 server running in Container Manager on orca, at `http://orca.ciliber.to:3900`. Garage keeps its data in `/volume1/kubernetes-backup/s3`, so Snapshot Replication copies it to volume 3 with the other backups.

Each cluster archives WAL continuously (at most 5 minutes behind) and takes a base backup daily at 01:00 UTC, keeping 30 days, so it can be restored to any point in that window. Each cluster has its own bucket and key, and the key is in a `cnpg-backup-s3` SealedSecret next to the cluster.

### Garage on orca

`/volume1/docker/garage/garage.toml`:

```toml
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
metadata_auto_snapshot_interval = "6h"
replication_factor = 1

rpc_bind_addr = "0.0.0.0:3901"
rpc_public_addr = "127.0.0.1:3901"
rpc_secret = "<openssl rand -hex 32>"

[s3_api]
# boto3 (Barman) signs with us-east-1 unless told otherwise.
s3_region = "us-east-1"
api_bind_addr = "0.0.0.0:3900"
```

Container Manager project at `/volume1/docker/garage`, `compose.yaml`:

```yaml
services:
  garage:
    image: dxflrs/garage:v2.4.1
    container_name: garage
    restart: unless-stopped
    ports:
      - "3900:3900"
    volumes:
      - /volume1/docker/garage/garage.toml:/etc/garage.toml:ro
      - /volume1/kubernetes-backup/s3/meta:/var/lib/garage/meta
      - /volume1/kubernetes-backup/s3/data:/var/lib/garage/data
```

One-time layout, then a bucket and key per cluster (over SSH on orca):

```sh
sudo docker exec garage /garage status   # note the node ID
sudo docker exec garage /garage layout assign -z orca -c 1T <node-id>
sudo docker exec garage /garage layout apply --version 1
for b in cnpg-forgejo cnpg-launch-forgejo cnpg-dsl-dashboard; do
  sudo docker exec garage /garage bucket create "$b"
  sudo docker exec garage /garage key create "$b"
  sudo docker exec garage /garage bucket allow --read --write --owner "$b" --key "$b"
done
sudo docker exec garage /garage key info --show-secret cnpg-forgejo   # key ID and secret
```

### Adding backups to a cluster

1. Create a bucket and key in Garage as above.
2. Seal the key into the app's `templates/sealed-secrets.yaml`:
   ```sh
   echo --- >> apps/<category>/<app>/templates/sealed-secrets.yaml
   kubectl create secret generic cnpg-backup-s3 -n <namespace> \
     --from-literal=ACCESS_KEY_ID=<key id> --from-literal=ACCESS_SECRET_KEY=<secret> \
     --dry-run=client -o yaml | kubeseal --cert sealed-secrets.crt -o yaml \
     >> apps/<category>/<app>/templates/sealed-secrets.yaml
   ```
3. Copy `templates/cnpg-backup.yaml` from `apps/lab/forgejo` (an `ObjectStore` and a `ScheduledBackup`) and add the `plugins` block to the `Cluster`, as in `apps/lab/forgejo/templates/cnpg-cluster.yaml`.

The secret must exist before the `Cluster` change syncs. Without it WAL archiving fails and WAL piles up on the volume until it fills.

### Restoring

Restore into a new cluster (a different name, or the same name after deleting the old one and moving its bucket contents aside, since Barman refuses to archive into a non-empty path):

```yaml
spec:
  bootstrap:
    recovery:
      source: origin
      # Optional point in time; without it, recovery replays all archived WAL.
      recoveryTarget:
        targetTime: "2026-10-22 12:00:00+00"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: forgejo-db-backup
          serverName: forgejo-db
```

If the cluster is gone, start Garage on any Docker host from the replicated `s3` folder and point an `ObjectStore` at it.

## Fresh Cluster Bootstrap

1. Install Cilium (ArgoCD needs a CNI to run; ArgoCD adopts this release later):
   ```sh
   helm dependency build apps/core/cilium
   helm install cilium apps/core/cilium -n cilium --create-namespace
   ```
   The BGP and LoadBalancer pool resources need CRDs that the Cilium operator creates on startup, so remove `templates/bgp.yaml` for this first install (or re-run it once the operator is up); ArgoCD applies them later.
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
