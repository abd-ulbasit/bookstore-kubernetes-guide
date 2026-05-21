# 01 — Bookstore end-to-end

> From an empty machine to a GitOps-delivered, observed, autoscaled, secured,
> backed-up Bookstore — every Part, one run. This is the whole guide as a
> single, ordered, runnable session: stand the system up from nothing, prove
> each production concern with its own check, then tear it down — orchestrating
> only artifacts the earlier parts already built.

**Estimated time:** ~45 min read · half-day hands-on
**Prerequisites:** [Part 07 ch.04](../07-delivery/04-gitops-argocd.md) — Argo CD reconciles the Kustomize overlays · [Part 07 ch.05](../07-delivery/05-progressive-delivery.md) — the catalog Rollout for canary delivery · [Part 06 ch.01](../06-production-readiness/01-observability-metrics.md) — Prometheus / Alertmanager assertions · [Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md) — Velero is part of the run · [Part 05 ch.02](../05-security/02-pod-security.md) — restricted PSA throughout
**You'll know after this:** • stand up the full Bookstore from an empty machine via GitOps, in one ordered run · • verify each production concern (security, observability, autoscaling, DR) with its own check · • reason about the same 49-object system rendered three ways (raw / Helm / Kustomize 45-49-48) · • drive a canary release end-to-end and watch Argo Rollouts roll back on bad metrics · • tear down the cluster cleanly and explain what each Part contributed

<!-- tags: capstone, bookstore-v1, gitops, observability, security, day-2 -->

## Why this exists

Parts 00–08 taught one concern per chapter and grew **one** application —
the Bookstore — to carry each. By the end, the example tree holds a complete
production shape: a 4-service app plus 3 stateful backends
(Postgres/Redis/RabbitMQ) ([Part 00 ch.02](../00-foundations/02-containers-and-images.md)),
the raw manifests, a Helm chart, Kustomize overlays, Argo CD Applications, an
Argo Rollout, Velero backups, a DR runbook, and operator manifests. Each was
proven *in isolation*, in the chapter that introduced it. (The
`raw-manifests/` files are numbered up to `84-` but total **49 deployable
objects**; the Helm chart renders the same 49, the prod Kustomize overlay
renders **48** — minus the demo Secret — and dev **45**. Those three numbers
recur below and are the same system rendered three ways.)

That leaves one question a learner cannot answer from the chapters alone, and
it is the question production actually asks: **do the pieces compose?** A
Deployment that rolls cleanly, an HPA that scales, a NetworkPolicy that
isolates, an Argo CD that reconciles, a Velero that restores — each works on
its own. This end-to-end walkthrough exists to prove they work **together, in one cluster, in
the right order**, with nothing hand-tuned between them. It is three things at
once:

1. **A composition proof.** Every layer is switched on against the same live
   system and checked, so "it all fits" stops being an assumption.
2. **A reference runbook.** The exact ordered sequence to bring the whole
   Bookstore up on a fresh cluster — the canonical fresh-cluster path the rest
   of the guide pointed forward to (it is what
   [Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md)'s Scenario 3
   "rebuild from zero" *is*, made explicit).
3. **The "did I actually learn this" capstone.** If you can run this end-to-end
   and explain *why* each step is where it is, you have the zero-to-production
   skill the guide set out to teach.

It introduces **no new application manifests**. Every command below
`kubectl apply`s, `helm install`s, `kubectl apply -k`s, or Argo-syncs a file
that already exists, plus verification and observation commands. Composition,
not construction.

## Mental model

The finished Bookstore is **one platform made of independent reconciled
layers, none of which knows about the others**, all driven from a single
source of truth.

- **Everything is a reconciliation loop.** The kubelet reconciles Pods to
  PodSpecs ([Part 00 ch.05](../00-foundations/05-node-components.md)); the
  Deployment/ReplicaSet controllers reconcile Pods to a template
  ([Part 01 ch.04](../01-core-workloads/04-replicasets-and-deployments.md));
  the HPA reconciles replica count to a metric
  ([Part 06 ch.04](../06-production-readiness/04-autoscaling.md)); Argo CD
  reconciles the live cluster to Git
  ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)); Argo Rollouts
  reconciles traffic to an analysis verdict
  ([Part 07 ch.05](../07-delivery/05-progressive-delivery.md)); Velero
  reconciles backup existence to a Schedule
  ([Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md)). The same
  level-triggered idea ([Part 00 ch.06](../00-foundations/06-declarative-api-model.md))
  at every layer is *why* the system self-heals: a deleted Pod, a drifted
  Deployment, a lost canary, a scaled-down node — each is just "observed ≠
  desired" and a controller fixes it without a human.
- **Git is the source of truth.** The cluster is *derived* state. The truth of
  "what should run" lives in the Kustomize overlays
  ([Part 07 ch.02](../07-delivery/02-packaging-kustomize.md)); Argo CD makes
  the cluster match and self-heals drift. Recovering the cluster is therefore
  *re-pointing Argo at Git* — except for the **data**, which Git cannot hold
  and Velero must.
- **Each layer is one orthogonal concern that composes by contract, not by
  coupling.** Workloads don't know they're being scraped; the NetworkPolicy
  doesn't know about the HPA; the Rollout doesn't know Velero exists. They
  compose because they all act on the *same declarative objects* through the
  *same API server*, each watching only its slice. That decoupling is the
  whole reason the stack is operable: you can reason about — and break, and
  fix — one layer at a time. The eight Parts map 1:1 onto eight such layers
  (workloads, networking, config/storage, scheduling, security,
  observability, delivery, day-2), and this end-to-end walkthrough is the demonstration that
  stacking all eight on one app yields a coherent system rather than a pile of
  YAML.

## Diagrams

### The final system (Mermaid)

```mermaid
flowchart TB
    user(["User / Browser"])
    git[["Git remote<br/>(Kustomize overlays =<br/>source of truth)"]]
    obj[["Object store<br/>(Velero backups,<br/>outlive the cluster)"]]

    subgraph kind["kind cluster (1 control-plane + 3 workers)"]
        cp["control-plane<br/>api-server · etcd ·<br/>scheduler · controllers"]

        subgraph argons["ns argocd"]
            argo["Argo CD<br/>app-controller · repo-server<br/>(reconciles Git to cluster)"]
        end

        subgraph rolloutsns["ns argo-rollouts"]
            rollouts["Argo Rollouts<br/>controller<br/>(canary + analysis)"]
        end

        subgraph monns["ns monitoring"]
            prom["Prometheus<br/>(scrapes /metrics<br/>via ServiceMonitor)"]
            graf["Grafana<br/>(RED dashboards)"]
        end

        subgraph bookns["ns bookstore (PSA: restricted)"]
            ing["Ingress (ingress-nginx)<br/>TLS · host/path routing"]
            sf["storefront<br/>Deployment + PDB"]
            cat["catalog<br/>Rollout (canary)<br/>+ HPA + PDB"]
            ord["orders<br/>Deployment + PDB"]
            pw["payments-worker<br/>Deployment + KEDA"]
            pg[("postgres<br/>StatefulSet + PVC")]
            rd[("redis<br/>cache")]
            mq[["rabbitmq<br/>queue"]]
            np["NetworkPolicies<br/>(default-deny + allows)"]
        end

        velero["Velero<br/>(ns velero)<br/>scheduled backup"]
    end

    user -->|HTTPS| ing
    ing -->|/| sf
    ing -->|/api/books| cat
    ing -->|/api/orders| ord
    cat -->|read| pg
    cat -->|cache| rd
    ord -->|write| pg
    ord -->|publish| mq
    mq -->|consume| pw
    git -.->|pull + reconcile| argo
    argo -.->|sync prod overlay| bookns
    rollouts -.->|canary + analysis| cat
    prom -.->|scrape| cat
    prom --> graf
    velero -.->|backup ns + PV| obj
    np -.-|enforced on| bookns
```

### Part → concern → where it lives (ASCII)

```text
PART                  CONCERN(S)                      ARTIFACT IT LIVES IN
────────────────────  ──────────────────────────────  ──────────────────────────────────
00 Foundations        cluster + container model       kind config; app/ Dockerfiles
01 Core Workloads     Deployments/StatefulSet/Job,    raw-manifests 10-/11-/14-/19-/
                      health, resources/QoS           20-/21-/22-  (Helm/Kustomize base)
02 Networking         Services, DNS, Ingress,         40-services / 50-ingress /
                      NetworkPolicy                   60-networkpolicy
03 Config & Storage   ConfigMap, Secret, PV/PVC       15-catalog-config / 16-db-creds /
                                                      20- volumeClaim  (StorageClass =
                                                      kind default; 17- not applied here)
04 Scheduling         affinity/taint/topology,        spread+antiAffinity in 10-/...;
                      priority                        35-priorityclasses
05 Security           RBAC, Pod Security, supply      05-serviceaccounts-rbac;
                      chain                           restricted SC in every workload;
                                                      70-kyverno-policy
06 Prod Readiness     metrics, autoscale, PDB         80-servicemonitor / 81-rule /
                                                      82-hpa / 83-keda / 84-pdb
07 Delivery           Helm, Kustomize, GitOps,        helm/bookstore; kustomize/*;
                      progressive delivery            argocd/*; argocd/rollouts/*
08 Day-2 Ops          backup/DR, troubleshooting,     operators/velero-*;
                      multi-tenancy, operators        operators/DR-RUNBOOK.md;
                                                      operators/cnpg-cluster.yaml
09 Capstone           compose ALL of the above        THIS chapter (orchestration only)
```

## Hands-on with the Bookstore

This is the run. It is **self-bootstrapping**: it starts from no cluster and
ends with a teardown; after `kind delete && kind create` every step below
re-runs identically (that is the point — it is the canonical fresh-cluster
path). All paths are **relative to the guide repo root**
(`full-guide/`); a couple of steps `cd` into `examples/bookstore/app` and
`cd` back — that is called out each time. The `bookstore` namespace enforces
**PSA `restricted`**, so every ad-hoc pod below uses restricted-compliant
`--overrides` (or runs in `default` with a stated reason); distroless services
are debugged with `kubectl debug --profile=restricted`, never `exec … sh`.

> **Pin every chart version.** Each `helm install` below shows
> `--version "$<TOOL>_CHART_VERSION"`. Set these to the current pinned chart
> versions for your date (the source chapters do the same). This guide's rule —
> reaffirmed here — is **never** `kubectl apply -f .../releases/latest/download/<FILE>.yaml`
> (it 404s when a release ships); install operators via their **Helm chart at a
> pinned version**, each into its **own namespace**.

> **What is illustrative (stated once, recapped in Production notes).** Three
> things are laptop approximations of a real environment, each an established
> precedent from the earlier parts: (1) the **Git remote** Argo CD pulls from —
> real GitOps needs a hosted repo + a deploy key/SSO; the runnable local
> approximation is given below; (2) the **object store** Velero writes to — a
> local MinIO stands in for S3 (identical API); (3) **no OIDC/cloud LB/managed
> etcd** — kind fakes the machines, not the API
> ([Part 00 ch.07](../00-foundations/07-local-cluster-setup.md)). Everything
> else is real Kubernetes.

### (a) Cluster — a multi-node kind cluster

A single-node kind cluster runs the app, but this walkthrough proves **scheduling
spread** ([Part 04 ch.02](../04-scheduling/02-affinity-taints-topology.md)) and
**PDB-respecting drains** ([Part 06 ch.05](../06-production-readiness/05-reliability-and-disruptions.md)),
both of which need ≥2 worker nodes. We use the canonical multi-node config the
guide established in Part 04 ch.02 (1 control-plane + 3 workers; synthetic zone
labels; one dedicated, tainted DB node), plus `extraPortMappings` so the
Ingress is reachable on `localhost` ([Part 02 ch.04](../02-networking/04-ingress.md)).
Save as `kind-capstone.yaml` (infra, **not** a Bookstore manifest):

```yaml
# kind-capstone.yaml — Part 04 ch.02 multi-node pattern + Part 02 ch.04 ingress
# port mappings. Worker-3 is the dedicated DB node (label + NoSchedule taint
# registered at join via kubeadmConfigPatches). Synthetic zone labels let us
# demo zone spread locally (real clusters get topology.kubernetes.io/zone from
# the cloud provider — Part 00 ch.07 In-production note).
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  protocol: TCP }
      - { containerPort: 443, hostPort: 443, protocol: TCP }
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-a
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-b
  - role: worker
    labels:
      topology.kubernetes.io/zone: zone-b
      dedicated: database          # postgres' nodeAffinity prefers this
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          taints:
            - key: dedicated
              value: database
              effect: NoSchedule    # repels everything lacking the toleration
```

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore --config kind-capstone.yaml
kubectl get nodes -L topology.kubernetes.io/zone,dedicated   # 1 cp + 3 workers
```

> Single-node fallback: `kind create cluster --name bookstore` works for steps
> (b)–(f), (h)–(l); the spread/drain checks in (g) degrade gracefully (they
> note "needs ≥2 nodes"). The multi-node config is preferred for the full run.
> Cluster lifecycle (versions, upgrades, the "rebuild from zero" property) is
> [Part 08 ch.01](../08-day-2-operations/01-cluster-lifecycle.md); the
> create/teardown contract is [Part 00 ch.07](../00-foundations/07-local-cluster-setup.md).

### (b) Images — build and load the four services

The Bookstore images are local (`bookstore/<SVC>:dev`); a kind node cannot
pull them from a registry, so they must be **loaded** into the node
([Part 00 ch.02](../00-foundations/02-containers-and-images.md) /
[ch.07](../00-foundations/07-local-cluster-setup.md)). This step `cd`s into the
app dir and `cd`s back:

```sh
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do
  docker build -t bookstore/$s:dev ./$s
done
cd ../../..                                  # back to guide repo root
for s in catalog orders payments-worker storefront; do
  kind load docker-image bookstore/$s:dev --name bookstore
done
docker exec bookstore-control-plane crictl images | grep bookstore  # loaded
```

(The four images are distroless — `catalog`/`orders`/`payments-worker` are
`gcr.io/distroless/static:nonroot` (UID 65532), `storefront` is nginx-unprivileged
(UID 101). That is why every workload is restricted-compliant and why step (k)
debugs them with `kubectl debug`, not `exec sh`.)

### (c) Platform operators — pinned Helm, each in its own namespace

Six platform components, each installed from its **Helm chart at a pinned
version** into its **own namespace**. Each install creates the CRDs the later
steps depend on — *order matters*: the operators must exist before any
resource that references their CRDs (else `no matches for kind …`, the
documented CRD-intrinsic behaviour every CRD-backed manifest in this guide
carries).

```sh
# 1) ingress-nginx — the L7 edge (Part 02 ch.04). Helm chart, kind-friendly
#    values (hostPort + the kind extraPortMappings from step (a)).
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --version "$INGRESS_NGINX_CHART_VERSION" \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=ClusterIP \
  --set controller.publishService.enabled=false --wait
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
kubectl get ingressclass        # an IngressClass "nginx" now exists

# 2) kube-prometheus-stack — metrics plane (Part 06 ch.01). Release name MUST be
#    kube-prometheus-stack: the ServiceMonitor/PrometheusRule `release:` label
#    (80-/81-) must match Prometheus's selector.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KPS_CHART_VERSION" \
  --namespace monitoring --create-namespace --wait
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-operator

# 3) Argo CD — GitOps engine (Part 07 ch.04). Its own ns; NOT PSA-restricted
#    (Argo's components are not restricted-shaped — same as the monitoring stack).
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace --wait
kubectl -n argocd rollout status deploy/argocd-server

# 4) Argo Rollouts — progressive delivery controller (Part 07 ch.05).
helm install argo-rollouts argo/argo-rollouts \
  --version "$ARGO_ROLLOUTS_CHART_VERSION" \
  --namespace argo-rollouts --create-namespace --wait
kubectl -n argo-rollouts rollout status deploy/argo-rollouts

# 5) KEDA — event-driven autoscaling for payments-worker (Part 06 ch.04).
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda \
  --version "$KEDA_CHART_VERSION" \
  --namespace keda --create-namespace --wait
kubectl -n keda rollout status deployment/keda-operator

# 6) Kyverno — policy engine, Audit mode (Part 05 ch.03). Helm (the chart is
#    the supported install path that sidesteps the apply-annotation size limit
#    of the raw bundle — ch.03 names Helm explicitly as that path).
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update
helm install kyverno kyverno/kyverno \
  --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace --wait
kubectl -n kyverno rollout status deploy/kyverno-admission-controller

# 7) Velero — backup/DR (Part 08 ch.02). A local MinIO is the S3-compatible
#    object store the cluster can reach (the laptop substitute for a real
#    bucket; identical S3 API — the established honesty note). kind's
#    local-path is NOT CSI-snapshot-capable, so node-agent filesystem backup
#    is the runnable path (snapshotsEnabled=false), exactly as ch.02 does.
VELERO_AWS_PLUGIN=v1.11.0            # velero-plugin-for-aws image tag (pin)
kubectl create namespace velero
helm repo add minio https://charts.min.io/ && helm repo update
helm install minio minio/minio -n velero \
  --version "$MINIO_CHART_VERSION" \
  --set rootUser=minio,rootPassword=minio12345 \
  --set 'buckets[0].name=velero,buckets[0].policy=none' \
  --set resources.requests.memory=512Mi --set replicas=1 --set mode=standalone --wait
cat > /tmp/velero-s3-creds <<'EOF'
[default]
aws_access_key_id=minio
aws_secret_access_key=minio12345
EOF
kubectl create secret generic velero-cloud-credentials -n velero \
  --from-file=cloud=/tmp/velero-s3-creds
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts && helm repo update
helm install velero vmware-tanzu/velero -n velero \
  --version "$VELERO_CHART_VERSION" \
  --set "initContainers[0].name=velero-plugin-for-aws" \
  --set "initContainers[0].image=velero/velero-plugin-for-aws:${VELERO_AWS_PLUGIN}" \
  --set "initContainers[0].volumeMounts[0].mountPath=/target" \
  --set "initContainers[0].volumeMounts[0].name=plugins" \
  --set configuration.backupStorageLocation[0].name=default \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket=velero \
  --set configuration.backupStorageLocation[0].config.region=minio \
  --set configuration.backupStorageLocation[0].config.s3ForcePathStyle=true \
  --set configuration.backupStorageLocation[0].config.s3Url=http://minio.velero.svc:9000 \
  --set credentials.existingSecret=velero-cloud-credentials \
  --set deployNodeAgent=true --set snapshotsEnabled=false --wait
kubectl -n velero rollout status deploy/velero
```

**The CRD transition.** Each install above registers CRDs: ingress-nginx →
none (built-in `Ingress`); kube-prometheus-stack → `ServiceMonitor`,
`PrometheusRule`; Argo CD → `Application`, `AppProject`; Argo Rollouts →
`Rollout`, `AnalysisTemplate`; KEDA → `ScaledObject`,
`TriggerAuthentication`; Kyverno → `ClusterPolicy`, `PolicyReport`; Velero →
`Backup`, `Restore`, `Schedule`, `BackupStorageLocation`. **Before** the
relevant install, a client dry-run of any manifest using that kind prints
`no matches for kind "<Kind>"` — the documented, expected CRD-intrinsic
behaviour every CRD-backed file in `examples/bookstore/` notes. **After** the
install, those same manifests validate and apply. This walkthrough installs all
the operators *first*, so every CRD-backed step that follows applies cleanly.

> Optional 8th operator — **CloudNativePG** (the production-grade Postgres
> alternative to the DIY StatefulSet). Not installed in the main run; see
> step (k) and [Part 08 ch.05](../08-day-2-operations/05-operators-and-crds.md).

### (d) GitOps bootstrap — Argo CD reconciles the prod overlay

The desired state of the Bookstore is the **Kustomize prod overlay**
(`examples/bookstore/kustomize/overlays/prod` → **48 objects**: base 49 minus
the demo Secret, which prod `$patch:delete`s — a real Secret of the same name
is supplied out-of-band by External Secrets/Sealed Secrets/Vault). Argo CD's
job is to make the cluster match it and self-heal drift
([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)).

**The honest bit — GitOps needs a Git remote.** The Argo CD `AppProject`
([`argocd/00-appproject.yaml`](../examples/bookstore/argocd/00-appproject.yaml))
and App-of-Apps root
([`argocd/01-app-of-apps.yaml`](../examples/bookstore/argocd/01-app-of-apps.yaml))
point `repoURL` at the clearly-marked placeholder
`https://github.com/your-org/bookstore.git`. Argo CD's repo-server **clones
that URL**; it does not read your local working copy. So the *real* form is:
push this repo to your Git host, replace `your-org`, and apply the two Argo
manifests — Argo then pulls `examples/bookstore/argocd/apps/`, creates the
three child Applications, and `bookstore-prod` syncs
`kustomize/overlays/prod`.

**Runnable local approximation** (no GitHub account; established precedent —
every "needs a real remote" point in this guide gives a local stand-in and
states the real form): serve this repo from an in-cluster Git over HTTP. The
concrete, robust local approximation is a one-pod Gitea:

```sh
# LOCAL GIT APPROXIMATION (real form: a hosted repo + deploy key / SSO).
# A throwaway in-cluster Git server holding THIS repo's content:
helm repo add gitea-charts https://dl.gitea.com/charts/ && helm repo update
helm install gitea gitea-charts/gitea -n gitea --create-namespace \
  --version "$GITEA_CHART_VERSION" \
  --set gitea.admin.username=bookstore --set gitea.admin.password=bookstore12345 \
  --set redis-cluster.enabled=false --set postgresql-ha.enabled=false \
  --set postgresql.enabled=true --wait
# Create a repo `bookstore`, push this guide repo's content to it, then set
#   repoURL: http://gitea-http.gitea.svc:3000/bookstore/bookstore.git
# in 00-appproject.yaml / 01-app-of-apps.yaml / apps/*.yaml (the ONE allowed,
# clearly-reversible runtime substitution: a placeholder→local-URL swap to
# drive the demo; revert by restoring the your-org placeholder). Real GitOps
# uses your actual Git host here.
```

> **Don't want to run Git at all?** The DR runbook's non-GitOps fallback is
> always available and is itself a documented, supported path: apply the prod
> overlay directly with `kubectl apply -k` (below, step (d.2)). GitOps is the
> *delivery mechanism*; the *artifact* is the same overlay either way. The
> capstone shows the GitOps path as primary (it is the guide's thesis) and the
> direct path as the honest, runnable fallback.

#### (d.1) Bootstrap order — non-negotiable

Whether Argo applies it or you do, the cumulative **bootstrap invariant** holds
(every flow that brings up catalog/orders must respect it, or you get
schema-missing CrashLoop and a `kubectl wait` timeout):

```text
00-namespace (+ PSA labels)  →  05-serviceaccounts-rbac  →  15-catalog-config
  →  16-db-credentials  →  35-priorityclasses  →  workloads
  →  21-db-migrate-job  →  kubectl wait --for=condition=complete job/db-migrate
  →  THEN kubectl wait deploy --all
```

The migration Job `21-` hardcodes `PGHOST=postgres`, so it only works against
the DIY Postgres StatefulSet path (the CNPG path rewires differently —
[Part 08 ch.05](../08-day-2-operations/05-operators-and-crds.md)).

**Argo CD handles this with sync waves.** As
[Part 07 ch.04](../07-delivery/04-gitops-argocd.md) covers (the db-migrate Job
as a PreSync/Sync-wave example, contrasted with the Helm hook from
[ch.01](../07-delivery/01-packaging-helm.md)), the Namespace/RBAC/config land
in an early wave, the StatefulSet/Deployments next, and the migration Job in a
wave after Postgres is up — Argo waits for each wave's resources to be healthy
before the next, which *is* the invariant, enforced declaratively. The base
manifests carry the wave annotations; Argo replays them on every sync.

#### (d.2) Apply the GitOps bootstrap

With Argo CD installed (step c) and `repoURL` pointing at your remote (or the
local Gitea approximation):

```sh
# Apply ONLY these two; Argo CD does the rest (App-of-Apps).
kubectl apply -n argocd -f examples/bookstore/argocd/00-appproject.yaml
kubectl apply -n argocd -f examples/bookstore/argocd/01-app-of-apps.yaml
#   → Argo syncs argocd/apps/ → creates bookstore-dev/staging/prod →
#     bookstore-prod syncs kustomize/overlays/prod (48 objects) into ns
#     bookstore, sync-waves enforcing the bootstrap order incl. 21- + its
#     completion gate before the rest goes Healthy.

# Watch Argo converge (CLI optional; first-run admin password):
kubectl -n argocd get applications
argocd app get bookstore-prod          # Synced / Healthy when converged
argocd app sync bookstore-prod         # force a sync if impatient
```

**Direct (non-GitOps) fallback — same overlay, no Git** (the DR runbook's
supported path; use this if not running a Git remote). Apply the bootstrap
prerequisites in order, then the overlay, then gate on the migration Job
**before** waiting on the Deployments:

> **kind users — do this first.** The prod overlay deliberately pins
> `registry.example.com/bookstore/...:1.0.0` images (the real production
> shape). Those do **not** exist on a kind cluster, so a verbatim
> `kubectl apply -k overlays/prod` → `kubectl wait` will **time out with
> `ImagePullBackOff`**. Before the `apply -k`, point the overlay at the
> kind-loaded `bookstore/<SVC>:dev` images from step (b) with the guide's
> established `kustomize edit set image` (same command CI runs — Part 07
> ch.03; key is the original `name:`, `bookstore/<SVC>`). This is a
> **reversible local-run override**: it does **not** change the canonical
> intent (prod genuinely uses the registry images) and is reverted at the end
> of the block. The simplest alternative is `overlays/dev` (45 objects,
> already `bookstore/<SVC>:dev`); the capstone keeps **prod as primary** with
> this documented local override (the spec's end-to-end targets the prod
> overlay).

```sh
# Prereqs in the invariant order (the overlay also contains these, but
# applying them first makes the ordering explicit and the migration safe):
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml

# KIND LOCAL-RUN OVERRIDE (run BEFORE apply -k): prod pins
# registry.example.com images that cannot pull on kind. Repoint the overlay's
# `images:` block to the kind-loaded bookstore/<SVC>:dev images (step (b)).
# `kustomize edit set image` keys on the ORIGINAL name (bookstore/<SVC>) — the
# exact pattern Part 07 ch.03 / CI use; no Deployment YAML is hand-edited.
# (kustomize is the standalone binary; recent kubectl also ships it.)
cd examples/bookstore/kustomize/overlays/prod
kustomize edit set image \
  bookstore/catalog=bookstore/catalog:dev \
  bookstore/storefront=bookstore/storefront:dev \
  bookstore/orders=bookstore/orders:dev \
  bookstore/payments-worker=bookstore/payments-worker:dev
cd ../../../../..                              # back to the guide repo root

# The whole prod overlay (48 objects) — workloads, Services, NetworkPolicies,
# StatefulSet, HPA, PDB, ServiceMonitor/PrometheusRule, the migration Job:
kubectl apply -k examples/bookstore/kustomize/overlays/prod

# GATE on the migration BEFORE waiting on Deployments (the invariant):
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=180s
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=300s
kubectl get pods,svc,netpol -n bookstore

# REVERT the local-run override so the overlay stays canonical (prod = the
# registry.example.com images; this edit was for the kind run only — exactly
# the `git checkout -- kustomization.yaml` revert Part 07 ch.03 shows):
cd examples/bookstore/kustomize/overlays/prod
git checkout -- kustomization.yaml 2>/dev/null \
  || kustomize edit set image \
       bookstore/catalog=registry.example.com/bookstore/catalog:1.0.0 \
       bookstore/storefront=registry.example.com/bookstore/storefront:1.0.0 \
       bookstore/orders=registry.example.com/bookstore/orders:1.0.0 \
       bookstore/payments-worker=registry.example.com/bookstore/payments-worker:1.0.0
cd ../../../../..
```

Either path, the end state is the same: storefront and catalog **Healthy**,
Postgres `Running` with a Bound PVC, the schema applied. (`overlays/prod`
canonically pins `registry.example.com/...:1.0.0` — the real production shape;
the override above is the documented, reverted kind-only local run. For a
*fully local* run with no override at all, use `overlays/dev` — 45 objects,
already `bookstore/<SVC>:dev`, the images you loaded in step (b). The dev
overlay is the zero-network path; prod is the real-shape path.)

### (e) Verify networking

Three checks ([Part 02](../02-networking/02-services.md)): the Ingress routes
externally, intra-cluster DNS resolves, and the default-deny NetworkPolicy
holds.

```sh
# Ingress reachable (kind extraPortMappings from step (a) → localhost:80).
# The prod overlay sets host bookstore.example.com; send that Host header:
curl -sS -H 'Host: bookstore.example.com' http://localhost/ | head -1
curl -sS -H 'Host: bookstore.example.com' http://localhost/api/books | head -c 200
#   (no port mappings? port-forward instead:
#    kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80 )

# Intra-mesh DNS + service routing, from a RESTRICTED ephemeral pod (the
# bookstore ns enforces PSA restricted — even a throwaway curl must comply):
kubectl run netcheck -n bookstore --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"netcheck","image":"curlimages/curl:8.10.1","command":["sh","-c","curl -fsS http://catalog.bookstore.svc.cluster.local/healthz && echo CAT-OK && curl -fsS http://storefront.bookstore.svc.cluster.local/ -o /dev/null && echo SF-OK"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'

# NetworkPolicy default-deny holding: a pod NOT allowed to reach postgres
# should TIME OUT (the 10 NetworkPolicies = default-deny + DNS-egress + both-
# ends allows; nothing but catalog/orders may reach postgres:5432).
kubectl run npblock -n bookstore --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"npblock","image":"curlimages/curl:8.10.1","command":["sh","-c","curl -m 5 -sS http://postgres.bookstore.svc.cluster.local:5432 || echo BLOCKED-AS-EXPECTED"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65532,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'
#   → BLOCKED-AS-EXPECTED  (default-deny + no allow for this pod = no path)
```

### (f) Verify observability

Prometheus discovers catalog via the **ServiceMonitor** the Operator turns
into scrape config ([Part 06 ch.01](../06-production-readiness/01-observability-metrics.md));
Grafana/PromQL show the RED signals; the PrometheusRule arms the alert.

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# Prometheus UI http://localhost:9090 → Status → Targets:
#   serviceMonitor/bookstore/... shows catalog endpoints UP (scrape of /metrics)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
# Grafana http://localhost:3000 (admin / prom-operator by default — change it)

# RED via PromQL (the series catalog's Go binary exports — Part 06 ch.01 §4):
#   request rate :  sum(rate(http_requests_total{namespace="bookstore"}[5m]))
#   error ratio  :  sum(rate(http_requests_total{namespace="bookstore",code=~"5.."}[5m]))
#                     / sum(rate(http_requests_total{namespace="bookstore"}[5m]))
#   p95 latency  :  histogram_quantile(0.95, sum by (le)
#                     (rate(http_request_duration_seconds_bucket{handler="books"}[5m])))

# The PrometheusRule alert (81-) is loaded; confirm it is armed:
kubectl -n monitoring get prometheusrule
# Prometheus UI → Alerts: the catalog error-rate alert shows Inactive
# (healthy) — it goes Firing only when the error ratio breaches its `expr`.
```

### (g) Verify scaling & reliability

Three independent mechanisms ([Part 06 ch.04](../06-production-readiness/04-autoscaling.md)
/ [ch.05](../06-production-readiness/05-reliability-and-disruptions.md)): the
HPA scales catalog on CPU, KEDA scales payments-worker on queue depth, and a
PDB keeps catalog available through a node drain.

```sh
# --- HPA: drive load, watch catalog scale out then back in ---
# (prod overlay HPA: minReplicas 4 / maxReplicas 12. Restricted load pod —
#  pinned rakyll/hey, runs fine non-root.)
kubectl run hey -n bookstore --rm -it --restart=Never \
  --image=ghcr.io/rakyll/hey:0.1.4 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"hey","image":"ghcr.io/rakyll/hey:0.1.4","args":["-z","3m","-c","50","http://catalog.bookstore.svc.cluster.local/books"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}' &
watch kubectl get hpa,deploy/catalog -n bookstore
#   → catalog REPLICAS climb toward maxReplicas under load, then settle back
#     to minReplicas after the stabilization window once load stops.

# --- KEDA: scale payments-worker on RabbitMQ queue depth ---
# orders only publishes when AMQP_URL is set. This is a DEMO-ONLY runtime
# override on the LIVE Deployment (NOT an edit to 14-/the manifest); reverted
# below — the exact reversible pattern Part 06 ch.04 establishes.
kubectl set env deployment/orders -n bookstore \
  AMQP_URL="amqp://guest:guest@rabbitmq.bookstore.svc.cluster.local:5672/"
kubectl rollout status deployment/orders -n bookstore
kubectl run flood -n bookstore --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"flood","image":"curlimages/curl:8.10.1","command":["sh","-c","for i in $(seq 1 500); do curl -s -o /dev/null -XPOST http://orders.bookstore.svc.cluster.local/orders -d \"{\\\"book_id\\\":1,\\\"qty\\\":1}\"; done; echo done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}'
watch kubectl get scaledobject,deploy/payments-worker -n bookstore
#   → KEDA scales payments-worker from 0/1 up toward maxReplicaCount as the
#     'orders' queue grows, then back to 0 once drained (scale-to-zero).
# REVERT the demo-only change (restore canonical AMQP_URL-unset behaviour):
kubectl set env deployment/orders -n bookstore AMQP_URL-
kubectl rollout status deployment/orders -n bookstore

# --- PDB: a node drain must NOT take all catalog replicas at once ---
# (needs ≥2 worker nodes — the multi-node config from step (a).)
kubectl get pdb -n bookstore                              # catalog minAvailable:2
node=$(kubectl get pods -n bookstore -l app=catalog \
  -o jsonpath='{.items[0].spec.nodeName}')
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s
#   → eviction proceeds POD-BY-POD; the PDB blocks an eviction that would drop
#     catalog below minAvailable — capacity preserved through a planned drain.
kubectl get pods -n bookstore -o wide -l app=catalog      # rescheduled, never all-down
kubectl uncordon "$node"                                  # restore the node
```

### (h) Verify security posture

Four checks ([Part 05](../05-security/02-pod-security.md)): PSA `restricted`
actually bites, NetworkPolicy isolates (proven in (e)), Kyverno's Audit policy
produces a report, and the ServiceAccounts are least-privilege.

```sh
# PSA negative control — a privileged pod MUST be rejected at admission:
kubectl run psa-bad -n bookstore --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"psa-bad","image":"busybox:1.36","securityContext":{"privileged":true}}]}}'
#   → Error ... violates PodSecurity "restricted:latest": privileged ...
#     (rejected; nothing created — proof enforce is live).

# Kyverno Audit policy report (Part 05 ch.03 — Audit, not Enforce, by design):
kubectl get clusterpolicy
kubectl get policyreport -n bookstore        # PASS/FAIL rows per workload
#   (the hardened workloads PASS the non-root/no-:latest/digest rules; Audit
#    surfaces violations without blocking — the deliberate ch.03 stance.)

# Least-privilege SAs: 8 SAs exist; only catalog-sa is RoleBound; app pods set
# automountServiceAccountToken:false (Part 05 ch.01).
kubectl get sa -n bookstore
kubectl auth can-i --list \
  --as=system:serviceaccount:bookstore:catalog-sa -n bookstore | head
#   → a TIGHT verb/resource set (only what catalog needs), not cluster-admin.
```

### (i) Progressive delivery — canary with auto-promote then auto-rollback

The catalog Rollout ([`argocd/rollouts/catalog-rollout.yaml`](../examples/bookstore/argocd/rollouts/catalog-rollout.yaml))
replaces the catalog Deployment with a metric-gated canary
([Part 07 ch.05](../07-delivery/05-progressive-delivery.md)): 10→25→50→100%
with an `AnalysisTemplate` gate (success-rate + p95, real PromQL against the
Part 06 catalog metrics). A passing analysis auto-promotes; a failing one
auto-rolls-back — no human, no `kubectl rollout undo`.

> The Rollout **owns** `.spec.replicas`; do **not** apply the `82-` HPA
> alongside it (it targets a `Deployment/catalog` the Rollout replaces —
> orphaning the autoscaler, the documented Rollout↔HPA interaction). This step
> stands the Rollout up on its own prereqs, separate from the (d) overlay's
> catalog Deployment, exactly as ch.05's hands-on does.

```sh
# Prereqs (catalog config/secret/SA/priority/Service + the AnalysisTemplates):
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/argocd/rollouts/analysistemplate-success-rate.yaml
kubectl apply -f examples/bookstore/argocd/rollouts/analysistemplate-latency.yaml
kubectl apply -f examples/bookstore/argocd/rollouts/catalog-rollout.yaml
kubectl argo rollouts get rollout catalog -n bookstore --watch &

# (1) Healthy canary → AUTO-PROMOTE: a normal new image; metrics stay green,
#     analysis passes, the canary is promoted to 100% automatically.
kubectl argo rollouts set image catalog -n bookstore catalog=bookstore/catalog:dev
#   → 10% → pause → 25% → pause → ANALYSIS (p95 ≤0.5s, success-rate OK) →
#     50% → pause → 100% promote. No human.
kubectl get analysisrun -n bookstore                       # Successful

# (2) Induce the metric gate → AUTO-ROLLBACK. The demo binary is healthy, so
#     we attack the LATENCY signal honestly: saturate catalog past its tiny
#     CPU limit so p95 blows past the 0.5s gate the AnalysisTemplate enforces
#     (the deterministic, reproducible failure ch.05 documents).
kubectl argo rollouts set image catalog -n bookstore catalog=bookstore/catalog:dev
kubectl run hammer -n bookstore --restart=Never \
  --image=ghcr.io/rakyll/hey:0.1.4 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"hammer","image":"ghcr.io/rakyll/hey:0.1.4","args":["-z","8m","-c","200","http://catalog.bookstore.svc.cluster.local/books"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}}]}}'
#   → reaches ANALYSIS → p95 from the histogram exceeds 0.5s under 200
#     clients → successCondition fails → after failureLimit(3) the
#     AnalysisRun FAILS → the Rollout ABORTS: canary→0, stable→100%
#     (automated rollback, before a full rollout, no kubectl rollout undo).
kubectl get analysisrun -n bookstore                       # Failed
kubectl argo rollouts get rollout catalog -n bookstore     # Degraded → stable
kubectl delete pod hammer -n bookstore                     # stop the load
```

### (j) Backup & DR drill — scheduled backup, then a PVC-loss restore

Velero is installed (step c). Apply the **scheduled** backup
([`operators/velero-schedule.yaml`](../examples/bookstore/operators/velero-schedule.yaml)) —
a recurring, PV-inclusive `bookstore` backup with a pre-backup Postgres
CHECKPOINT consistency hook ([Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md)) —
then run **DR Scenario 2** from the runbook
([`operators/DR-RUNBOOK.md`](../examples/bookstore/operators/DR-RUNBOOK.md)):
the Postgres PVC is lost; declarative state is fine; only a data backup
recovers it.

```sh
kubectl apply -f examples/bookstore/operators/velero-schedule.yaml
velero schedule describe bookstore-daily
# Trigger one now instead of waiting for the cron (drill):
velero backup create bookstore-drill --from-schedule bookstore-daily
velero backup describe bookstore-drill --details        # Phase: Completed

# --- DR Scenario 2: Postgres PVC lost/corrupted (the real DR case) ---
# 1) Stop writers, then stop Postgres (RWO PVC must be unmounted to restore):
kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
  -n bookstore --replicas=0
kubectl scale statefulset/postgres -n bookstore --replicas=0
kubectl wait --for=delete pod/postgres-0 -n bookstore --timeout=120s
# (simulate the loss: delete the PVC so the restore must recreate it)
kubectl delete pvc data-postgres-0 -n bookstore

# 2) Restore ONLY the data (declarative objects come back via GitOps, NOT the
#    backup). Scope by ns + resource kind — NOT --selector app=postgres: the
#    StatefulSet controller does not copy pod labels onto the volumeClaim PVC,
#    so a label-selected restore silently skips it (the runbook's key warning):
velero backup get
velero restore create bookstore-pgrestore \
  --from-backup bookstore-drill \
  --include-namespaces bookstore \
  --include-resources persistentvolumeclaims,persistentvolumes
velero restore describe bookstore-pgrestore --details   # Phase: Completed

# 3) Bring Postgres back on the restored PVC, then writers:
kubectl scale statefulset/postgres -n bookstore --replicas=1
kubectl rollout status statefulset/postgres -n bookstore --timeout=120s
kubectl scale deploy/catalog deploy/orders deploy/payments-worker \
  -n bookstore --replicas=2

# 4) Validate the DATA is actually back (postgres image has a shell — it is
#    NOT distroless; this is the documented exception to the debug rule):
kubectl exec -n bookstore postgres-0 -- \
  psql -U bookstore -d bookstore -c '\dt'
kubectl exec -n bookstore postgres-0 -- \
  psql -U bookstore -d bookstore -c 'SELECT count(*) FROM books;'
#   → tables present, rows back. A green pod with an empty DB is NOT recovered
#     (the runbook's post-incident rule: verify data, not just readiness).
```

### (k) Day-2 sampler — one symptom diagnosed; the operator alternative

Diagnose one failure with the correct distroless tool
([Part 08 ch.03](../08-day-2-operations/03-troubleshooting-playbook.md)).
`catalog`/`orders`/`payments-worker` are distroless — `kubectl exec catalog -- sh`
returns `exec: "sh": executable file not found`. The right tool is
`kubectl debug` with an ephemeral container on `--profile=restricted` (PSA-
`restricted` constrains the debugger too):

```sh
# Symptom: "is catalog actually reaching postgres / what does it see?" — get a
# shell + network tools into catalog's namespaces WITHOUT a shell in the image:
kubectl debug -it -n bookstore deploy/catalog \
  --image=nicolaka/netshoot --target=catalog --profile=restricted -- /bin/bash
#   • --target=catalog → shares catalog's process+network namespace
#   • --profile=restricted (GA 1.30) → the ephemeral container is shaped
#     restricted-compliant so PSA admits it (a bare --image=busybox without
#     this profile is REJECTED by PSA — the documented contrast).
# Inside: `curl -s http://postgres.bookstore.svc.cluster.local:5432` /
#         `nslookup catalog` / `ss -tnp` — diagnose, exit; the ephemeral
#         container is discarded, the canonical manifest never touched.
```

**The production-grade Postgres alternative.** The DIY Postgres StatefulSet
is the teaching shape; production uses an **operator**. CloudNativePG
([`operators/cnpg-cluster.yaml`](../examples/bookstore/operators/cnpg-cluster.yaml),
[Part 08 ch.05](../08-day-2-operations/05-operators-and-crds.md)) is the
**additive alternative** (not a deletion — Gateway-vs-Ingress precedent):
install the CNPG operator (its own ns, pinned Helm chart), apply the `Cluster`,
and the `DB_DSN` rewires from `postgres` to the operator-created
`bookstore-db-rw` Service — shown reversibly in ch.05. It brings HA, failover,
and WAL/PITR (sub-snapshot RPO needs WAL/PITR, which the crash-consistent
Velero snapshot path cannot give).
Not run in the main capstone (the StatefulSet path keeps the run
self-contained); it is the documented next step toward real production.

### (l) Teardown

```sh
kill %1 %2 2>/dev/null || true          # stop any backgrounded port-forwards
kind delete cluster --name bookstore
```

The cluster — and everything in it: workloads, operators, the local MinIO,
the local Gitea — is gone. **What persists is what should:** the **Git
remote** (your real source of truth — declarative state survives the cluster)
and a real **object store** (Velero backups deliberately live outside the
cluster so they outlive it — that is *why* DR works). On a fresh
`kind create`, this entire chapter re-runs and rebuilds the system identically:
declarative state from Git, data from the backup. That round-trip — destroy,
recreate, reconcile, restore — is the whole guide in one sentence.

## How it works under the hood

This walkthrough is interesting precisely because nothing in it is new — it is the
**composition** that is the lesson.

- **Reconciliation, all the way down.** Every moving part is the same control
  loop ([Part 00 ch.06](../00-foundations/06-declarative-api-model.md)) at a
  different layer: kubelet→PodSpec, ReplicaSet→template, HPA→metric,
  KEDA→queue, Argo CD→Git, Argo Rollouts→analysis verdict, Velero→Schedule.
  None polls another; each watches its own desired/observed pair through the
  API server and acts. That is why the order in step (c) matters (a controller
  must exist before the objects it reconciles) and why nothing else needs
  orchestrating — once the loops are running, the system *converges itself*.
- **Level-triggered self-healing is emergent, not coded.** Delete a catalog
  Pod → the ReplicaSet observes `observed<desired` and remakes it. `kubectl
  edit` a Deployment at 2am → Argo CD observes `live≠Git` and reverts it.
  Saturate the canary → Rollouts observes the analysis fail and aborts. No
  component has "if X then heal" logic; each just continuously drives its slice
  toward desired. The system is robust because *every* layer has this property,
  so a perturbation at any layer is absorbed at that layer.
- **Git as source of truth splits the world cleanly into two recoverables.**
  Everything declarative — Namespace, RBAC, Deployments, Services,
  NetworkPolicies, the StatefulSet *object* — is in Git; a fresh Argo CD
  rebuilds it for free (step (d), DR Scenario 3). The **data** inside the
  Postgres PVC is *not* in Git and cannot be — it needs Velero (step (j)).
  This is exactly why backup and DR is two mechanisms, not one: GitOps-DR for
  desired state, Velero for data. Conflating them is the classic "I snapshotted
  etcd, I'm safe" outage ([Part 08 ch.02](../08-day-2-operations/02-backup-and-dr.md)).
- **The layers compose without coupling because they share substrate, not
  code.** The HPA, the NetworkPolicy, the ServiceMonitor, the Rollout, the PDB
  never call each other. They interact only through declarative objects on one
  API server, each watching its own kind. That is what lets you bring them up
  in sequence, verify each independently, break one and fix it, and swap one
  (StatefulSet→CNPG) without touching the rest. Decoupling-via-shared-
  declarative-state is the single architectural idea the whole guide has been
  building toward; the capstone is its proof.

## Production notes

> **In production:** what is different from this lab, at real scale —
>
> - **Control plane & etcd are managed.** EKS/GKE/AKS run (and back up) the
>   API server and etcd; you cannot `etcdctl` them and don't need to
>   ([Part 08 ch.01](../08-day-2-operations/01-cluster-lifecycle.md)). The
>   capstone's kind control-plane is the laptop substitute.
> - **A real object store.** Velero writes to actual S3/GCS/Azure Blob with
>   lifecycle policies and cross-region replication, not a single in-cluster
>   MinIO pod. The MinIO here is the established S3-API-identical stand-in.
> - **A real Git remote + identity.** Argo CD pulls from a hosted repo over a
>   deploy key/app token; humans authenticate via SSO/OIDC; prod often points
>   at a protected branch/separate config repo the app repo cannot push to
>   ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)). The placeholder
>   `your-org` repo and the local Gitea are the lab approximation.
> - **Multi-cluster delivery.** One `Application` per env on one cluster
>   becomes **ApplicationSets** generating Applications across many clusters
>   (ch.04). The App-of-Apps here is the single-cluster form.
> - **Mesh for exact canary traffic.** The replica-ratio canary (step (i),
>   shared Service) becomes precise percentage traffic-shifting via a service
>   mesh / Gateway API + Argo Rollouts `trafficRouting`
>   ([Part 07 ch.05](../07-delivery/05-progressive-delivery.md)). The lab stays
>   mesh-free deliberately.
> - **External secrets.** The prod overlay `$patch:delete`s the demo Secret;
>   the real `db-credentials` comes from External Secrets Operator / Sealed
>   Secrets / Vault ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)).
>   Never ship a real password in Git.
> - **HA everything + a real DB operator.** Multi-replica, zone-spread,
>   anti-affinity'd control plane and workloads (the spread is *demoed* here on
>   synthetic zones); Postgres via **CloudNativePG** with WAL/PITR, not the
>   teaching StatefulSet ([Part 08 ch.05](../08-day-2-operations/05-operators-and-crds.md)).
> - **Capacity & cost.** Real clusters add requests/limits tuning, VPA
>   recommendations, and a node autoscaler (Cluster Autoscaler/Karpenter) so
>   nodes track pod demand ([Part 06 ch.06](../06-production-readiness/06-capacity-and-cost.md)).
>
> **Honest recap of every lab approximation used here** (each an established
> precedent, never hidden): (1) kind fakes the machines, not the API
> ([Part 00 ch.07](../00-foundations/07-local-cluster-setup.md)); (2) the Git
> remote is a local Gitea / placeholder URL — real form stated; (3) the object
> store is a local MinIO — identical S3 API; (4) Velero uses **node-agent
> filesystem backup**, not CSI snapshots (kind's local-path is not
> snapshot-capable) — the restore scope is identical; (5) the canary is
> replica-ratio, not mesh-percentage; (6) zones are synthetic node labels;
> (7) the progressive-delivery rollback is triggered by an **honest induced
> latency breach** (the demo binary doesn't emit 5xx on demand — the PromQL is
> real, the failure injection is the documented illustrative part). None of
> these change the Kubernetes mechanics being demonstrated.

## Quick Reference

### Run the whole thing (compact ordered command list)

```sh
# (a) CLUSTER — multi-node kind (kind-capstone.yaml from §(a)) -----------------
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore --config kind-capstone.yaml

# (b) IMAGES ------------------------------------------------------------------
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done

# (c) PLATFORM OPERATORS — pinned Helm, own namespaces (set *_CHART_VERSION) ---
helm install ingress-nginx ingress-nginx/ingress-nginx --version "$INGRESS_NGINX_CHART_VERSION" -n ingress-nginx --create-namespace --set controller.hostPort.enabled=true --set controller.service.type=ClusterIP --wait
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version "$KPS_CHART_VERSION" -n monitoring --create-namespace --wait
helm install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace --wait
helm install argo-rollouts argo/argo-rollouts --version "$ARGO_ROLLOUTS_CHART_VERSION" -n argo-rollouts --create-namespace --wait
helm install keda kedacore/keda --version "$KEDA_CHART_VERSION" -n keda --create-namespace --wait
helm install kyverno kyverno/kyverno --version "$KYVERNO_CHART_VERSION" -n kyverno --create-namespace --wait
# + Velero (+ local MinIO) per §(c) step 7

# (d) GITOPS BOOTSTRAP — Argo reconciles the prod overlay (or the direct path) -
kubectl apply -n argocd -f examples/bookstore/argocd/00-appproject.yaml
kubectl apply -n argocd -f examples/bookstore/argocd/01-app-of-apps.yaml
#   ── OR direct (no Git remote), invariant order: ──
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
# kind: first `kustomize edit set image` the prod overlay to bookstore/<SVC>:dev
#       (see step (d), reverted after) — or use overlays/dev (45 objs, already
#       bookstore/<SVC>:dev). prod pins registry.example.com images that won't
#       pull on kind.
kubectl apply -k examples/bookstore/kustomize/overlays/prod
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=180s
kubectl wait --for=condition=available deploy --all -n bookstore --timeout=300s

# (e) NET   (f) OBS   (g) SCALE+PDB   (h) SEC   (i) CANARY   (j) BACKUP+DR
#     (k) DAY-2   — run each verification block from §(e)–(k) above.

# (l) TEARDOWN ----------------------------------------------------------------
kind delete cluster --name bookstore
```

### Production-readiness checklist — concern → chapter that covers it

| Concern | Chapter |
|---|---|
| Workloads (Deployment/StatefulSet/Job) | [01-core-workloads/04](../01-core-workloads/04-replicasets-and-deployments.md), [05](../01-core-workloads/05-statefulsets.md), [07](../01-core-workloads/07-jobs-and-cronjobs.md) |
| Health (probes, lifecycle) | [01-core-workloads/02](../01-core-workloads/02-health-and-lifecycle.md) |
| Resources & QoS | [01-core-workloads/03](../01-core-workloads/03-resources-and-qos.md) |
| Deployment strategies | [01-core-workloads/08](../01-core-workloads/08-deployment-strategies.md) |
| Networking (Services) | [02-networking/02](../02-networking/02-services.md) |
| DNS & service discovery | [02-networking/03](../02-networking/03-dns-and-discovery.md) |
| Ingress | [02-networking/04](../02-networking/04-ingress.md) |
| Config (ConfigMaps) | [03-config-and-storage/01](../03-config-and-storage/01-configmaps.md) |
| Secrets | [03-config-and-storage/02](../03-config-and-storage/02-secrets.md) |
| Storage (PV/PVC) | [03-config-and-storage/04](../03-config-and-storage/04-persistent-storage.md) |
| Scheduling (affinity/taint/topology/priority) | [04-scheduling/02](../04-scheduling/02-affinity-taints-topology.md), [03](../04-scheduling/03-priority-and-preemption.md) |
| RBAC (authn/authz) | [05-security/01](../05-security/01-authn-authz-rbac.md) |
| Pod security | [05-security/02](../05-security/02-pod-security.md) |
| Supply chain | [05-security/03](../05-security/03-supply-chain.md) |
| Observability (metrics) | [06-production-readiness/01](../06-production-readiness/01-observability-metrics.md) |
| Logging | [06-production-readiness/02](../06-production-readiness/02-logging.md) |
| Tracing | [06-production-readiness/03](../06-production-readiness/03-tracing.md) |
| Autoscaling (HPA/VPA/KEDA) | [06-production-readiness/04](../06-production-readiness/04-autoscaling.md) |
| Reliability & PDB | [06-production-readiness/05](../06-production-readiness/05-reliability-and-disruptions.md) |
| Capacity & cost | [06-production-readiness/06](../06-production-readiness/06-capacity-and-cost.md) |
| Packaging (Helm) | [07-delivery/01](../07-delivery/01-packaging-helm.md) |
| Packaging (Kustomize) | [07-delivery/02](../07-delivery/02-packaging-kustomize.md) |
| CI/CD | [07-delivery/03](../07-delivery/03-cicd-pipeline.md) |
| GitOps | [07-delivery/04](../07-delivery/04-gitops-argocd.md) |
| Progressive delivery | [07-delivery/05](../07-delivery/05-progressive-delivery.md) |
| Cluster lifecycle | [08-day-2-operations/01](../08-day-2-operations/01-cluster-lifecycle.md) |
| Backup & DR | [08-day-2-operations/02](../08-day-2-operations/02-backup-and-dr.md) |
| Troubleshooting | [08-day-2-operations/03](../08-day-2-operations/03-troubleshooting-playbook.md) |
| Multi-tenancy & namespaces | [08-day-2-operations/04](../08-day-2-operations/04-multi-tenancy-and-namespaces.md) |
| Operators & CRDs | [08-day-2-operations/05](../08-day-2-operations/05-operators-and-crds.md) |

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check. These are *capstone synthesis* questions — each pulls together multiple Parts.

1. **The chapter calls the system "one platform made of independent reconciled layers, none of which knows about the others." Pick three layers (e.g., HPA, NetworkPolicy, Argo CD) and explain in two sentences each how they remain independent yet compose into one coherent operation.**
   <details><summary>Show answer</summary>

   HPA watches `metrics.k8s.io` and patches `.spec.replicas`; it knows nothing about NetworkPolicy or Argo CD. NetworkPolicy is realized by the CNI's eBPF/iptables rules at packet time; it knows nothing about replicas or Git. Argo CD watches Git, renders Kustomize, and reconciles the live cluster; it knows nothing about HPA decisions (in fact, `ignoreDifferences` *prevents* it from touching `.spec.replicas`). They all act on the **same API objects** through the **same apiserver**, each watching only its slice — the apiserver is the shared coordination point; composition is by contract (object schema), not coupling. That's why you can debug one layer at a time. See §Mental model.

   </details>

2. **Scenario — the day starts with Prometheus paging on `BookstoreCatalogHighErrors`. Walk through the diagnostic path using the right tool from the right Part for each step, in order.**
   <details><summary>Show answer</summary>

   (1) **Prometheus UI** (Part 06 ch.01): confirm the alert and look at the 5xx rate / latency PromQL — is it widespread or one handler? (2) **`kubectl get pods -n bookstore` + describe + events** (Part 08 ch.03 method): are pods unhealthy / restarting / unscheduled? (3) **`kubectl logs --previous` on the affected pods** (Part 06 ch.02 / Part 08 ch.03): in-container error? (4) **Tempo/Jaeger** by `trace_id` from a failing log line (Part 06 ch.03): which span failed — Postgres, RabbitMQ, payments-worker? (5) **`kubectl debug --profile=restricted`** (Part 08 ch.03) if you need a shell in distroless. (6) Fix forward via **PR + Argo CD sync** (Part 07 ch.04), not `kubectl edit`. Each tool answers a different scope; the order is method.

   </details>

3. **The capstone deliberately renders the same 49-object app three ways: raw manifests (49), Helm chart (49), Kustomize overlays (45 dev / 49 staging / 48 prod). Why are these numbers exactly these — what's the dev minus, the prod minus, and what does this teach about packaging?**
   <details><summary>Show answer</summary>

   Dev (45): omits CRD-backed extras that need operators (no ServiceMonitor, no KEDA ScaledObject, sometimes no PDB) — components opt-OUT for lightweight local dev. Staging (49): full set, mirror of prod, for realistic pre-prod testing. Prod (48): full set **minus the demo Secret** (`16-db-credentials.yaml`) because in production credentials come from External Secrets / Vault, not Git. The lesson: packaging is the same app rendered differently per environment via *small, declarative overlays* (Kustomize) — the **delta is visible** in version control, not hidden in chart conditionals. The raw manifests prove the base is real, applyable YAML — no templating language required to understand it.

   </details>

4. **A new engineer asks "why do we need both Velero *and* Argo CD for DR? Couldn't Argo just restore everything from Git?" Give the precise answer that names which layers each tool owns.**
   <details><summary>Show answer</summary>

   Argo CD restores the **declarative state** (Layer 2): all Kubernetes objects — Deployments, Services, ConfigMaps, PVCs (the *object*), NetworkPolicies, RBAC. That covers everything *defined in Git*. Velero restores **PV data** (Layer 3): the bytes inside `data-postgres-0` PVC — books, orders, customer records — which Git **cannot hold** and Argo cannot recreate. They are complementary: `git revert` is a perfect rollback for declarative state; Velero+CSI is the only path for application data. Forgetting Velero means restoring an empty Postgres pointing at a clean PVC. The GitOps-DR insight is "Layer 2 is almost free"; the chapter's honesty is "Layer 3 still requires real backup mechanics."

   </details>

5. **Hands-on extension — induce a complete rollback, end-to-end. With the catalog Rollout running (Part 07 ch.05) and Velero scheduled (Part 08 ch.02), deploy a broken catalog image (e.g., one with deliberately injected latency). Watch the full chain react. What do you see in (a) Argo Rollouts, (b) Prometheus, (c) the catalog Service, (d) `git log` after a `git revert`?**
   <details><summary>What you should see</summary>

   (a) Argo Rollouts: canary advances to `setWeight: 10`, `AnalysisRun` queries Prometheus, fails the success-rate gate, transitions `AnalysisRun: Failed`, automatically aborts — canary ReplicaSet → 0, stable → 100%. (b) Prometheus: a brief 5xx spike on the 10% canary slice, then back to baseline as traffic returns to stable. (c) Service: never went down — `kubectl get endpoints catalog` shows healthy backends throughout because the Rollout kept the stable RS at full replicas. (d) `git revert HEAD` of the digest bump commit, push, Argo CD syncs the revert within minutes. The audit trail is `git log`; rollback was automatic; no human ran `kubectl rollout undo`. That's six chapters' worth of machinery composing into one verifiable property.

   </details>

6. **Why is "everything is a reconciliation loop" (kubelet, Deployment, HPA, Argo CD, Argo Rollouts, Velero) more than a stylistic observation — what concrete operational property does it give the platform?**
   <details><summary>Show answer</summary>

   **Self-healing convergence**: every layer is level-triggered + idempotent, so any transient failure (controller crash, missed event, network blip, manual mistake) is *not* terminal — the next reconcile fixes it. A deleted Pod gets recreated. A drifted Deployment gets reverted. An aborted canary scales the stable back. A failed Velero run retries from its Schedule. **You can break things and the system fixes itself**, which is the only sustainable property for a platform that survives 3am outages with sleepy operators. This is also why "kubectl edit" at 2am is bad — the same self-healing reverts your manual mitigation. The model only works if Git is the single write surface. The whole guide's through-line — Part 00's declarative model — is the property exercised here at scale.

   </details>

7. **The capstone is also a *teaching* checkpoint. If you can run this end-to-end and articulate *why* each step is where it is, you have the zero-to-production skill the guide set out to teach. Pick the step you found *least* obvious, name the chapter that should have prepared you, and write one sentence on what you'd reread.**
   <details><summary>What you should see</summary>

   (Open-ended — this is a self-assessment question; the answer is *your* answer.) Common ones: "Why does Argo Rollouts need `ignoreDifferences` on Deployment replicas?" → Part 07 ch.05 + Part 06 ch.04 on multi-owner conflict on `.spec.replicas`. "Why does the Velero backup need a pre-hook?" → Part 08 ch.02 / Part 03 ch.05 on crash-consistent vs transaction-consistent snapshots. "Why are images pinned by digest in prod and tag in dev?" → Part 05 ch.03 + Part 07 ch.03 on supply-chain provenance. The point of this question is: notice your gaps, name the chapter, reread that chapter, run that chapter's hands-on. The guide is a graph; the capstone is the test that the graph is connected for you.

   </details>

## Further reading

- **Rosso, Lander, Brand & Harris, _Production Kubernetes_, ch.1 — "A Path to
  Production"**: the primary citation for this chapter. The capstone *is* the
  book's central thesis enacted — production is not a feature you add at the
  end but the sum of many composed concerns (deployment, networking, secrets,
  observability, supply chain, day-2), each of which the guide built and this
  chapter stacks on one app. Re-read it with the Bookstore in mind.
- **_Argo CD Up & Running_ (whole book)**: the GitOps spine of steps (d), (i),
  (j) — App-of-Apps, sync waves/hooks, drift/self-heal, `git revert` as
  rollback, and ApplicationSets for the multi-cluster form noted in Production
  notes.
- **The earlier parts, as the real reference.** Every step here cross-links the
  chapter it came from; that chapter is the depth. This is the index; Parts
  00–08 are the content.
- **Official — Kubernetes "Production environment" / configuration best
  practices**: <https://kubernetes.io/docs/setup/production-environment/> and
  <https://kubernetes.io/docs/concepts/configuration/overview/> — the upstream
  checklist this guide operationalized end-to-end.
- **The CNCF Landscape**: <https://landscape.cncf.io/> — every operator
  installed in step (c) (ingress-nginx, Prometheus, Argo CD/Rollouts, KEDA,
  Kyverno, Velero, CloudNativePG) sits here; the map of what to reach for next.
- **Appendix (authored next; canonical paths):**
  [A — kubectl cheatsheet](../appendix/A-kubectl-cheatsheet.md) (keep open as
  you run this), [B — Glossary](../appendix/B-glossary.md),
  [C — YAML and API conventions](../appendix/C-yaml-and-api-conventions.md),
  [D — Further reading](../appendix/D-further-reading.md), and
  [E — Learning paths](../appendix/E-learning-paths.md) (the CKA/CKAD/CKS
  fast-tracks built on this guide).
