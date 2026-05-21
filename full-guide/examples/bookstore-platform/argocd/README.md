# `argocd/` — Argo CD Applications + ApplicationSet

The platform's delivery spine. The management cluster (us-east, by
convention) runs the single Argo CD instance; it has all three regional
clusters registered via `argocd cluster add` and fans the platform out by:

| File | Kind | What it deploys |
|------|------|-----------------|
| `applicationset-platform.yaml` | `ApplicationSet` (Cluster generator) | The platform-base stack into every region's cluster, using `../kustomize/regions/<REGION>/`. |
| `application-keycloak.yaml` | `Application` (Helm) | Bitnami Keycloak chart (pinned), realm imported from `../auth/keycloak-realm-import.cm.yaml`. |
| `application-crossplane.yaml` | `Application` (Helm) | crossplane-stable Crossplane chart (pinned), into `crossplane-system`. |

System operators (Crossplane, Keycloak) each get their OWN namespace + their
own pinned Helm chart. None of them install into a platform namespace; none
of them install via `releases/latest/download/<PINNED-FILE>.yaml`. That
discipline is the same hard invariant the v1 Bookstore follows for cnpg-
operator and ESO.

## Why the ApplicationSet over per-cluster Applications

Three regions today; tomorrow there could be six. The ApplicationSet Cluster
generator scales linearly with the cluster count, no copy-paste. The
Application name + the path-template do the rest. The Part 11 ch.06 pattern,
made the platform's spine.

## Apply order

```sh
# Install Argo CD itself (Part 07 ch.04 pinned-Helm install).
# Then register the three regional clusters with region labels:
argocd cluster add kind-bookstore-platform-us-east \
  --label bookstore-platform.example.com/region=us-east
argocd cluster add kind-bookstore-platform-eu-west \
  --label bookstore-platform.example.com/region=eu-west
argocd cluster add kind-bookstore-platform-ap-southeast \
  --label bookstore-platform.example.com/region=ap-southeast

# Apply the Applications + ApplicationSet (from the management cluster):
kubectl apply -f examples/bookstore-platform/argocd/application-crossplane.yaml
kubectl apply -f examples/bookstore-platform/argocd/application-keycloak.yaml
kubectl apply -f examples/bookstore-platform/argocd/applicationset-platform.yaml

kubectl get applications -n argocd
```

## CRD-intrinsic dry-runs

`Application` and `ApplicationSet` both fail `--dry-run=client` with the
documented `no matches for kind` message before Argo CD is installed.
