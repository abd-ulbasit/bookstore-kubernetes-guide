# 13.01 — Bookstore 2.0: from toy to platform

> What makes a production e-commerce platform on Kubernetes different from
> the v1 we built across Parts 00 - 09, and how the next eleven
> chapters get us there.

**Estimated time:** ~30 min read · ~20 min hands-on on one kind cluster
**Prerequisites:** [Part 09 ch.01](../09-end-to-end-bookstore/01-bookstore-end-to-end.md) — v1 Bookstore this chapter contrasts v2 with · [Part 11 ch.10](../11-advanced-production-patterns/10-platform-engineering.md) — platform-engineering frame v2 lives in
**You'll know after this:** • name the seven dimensions (tenancy, region, identity, delivery, data, ML, day-2) where v2 leaves v1 · • articulate why v2 is structurally a different artifact, not "v1 with more features" · • map each Part 13 chapter onto a v2 dimension · • describe the bookstore-platform-v2 directory layout · • justify when v1's small-on-purpose shape is the right choice

<!-- tags: bookstore-v2, mental-model, capstone, platform-engineering -->

## Why this exists

Part 13 calls that production artifact Bookstore v2; this chapter explains
what v2 means and why it is a different kind of artifact than v1.

The Bookstore the guide built across Parts 00 - 12 is **the right teaching
artifact for everything in those parts**. It is small on purpose: four
services + three stateful backends + a 49-object Helm chart + three
Kustomize overlays (45 / 49 / 48). One service per concern. One DB. One
namespace. One region. A shared-HMAC toy JWT for "auth". A rule-based
"recommender". The whole thing fits in a `kind` cluster on a laptop and runs
the full Parts 00 - 09 narrative end-to-end without ever leaving that
laptop.

The v1 Bookstore is **not the production reality**. A real e-commerce
business running on Kubernetes today looks structurally different along
seven dimensions:

1. **Tenancy.** It is not one bookstore; it is N bookstores running on the
   same platform. Each is a tenant. Onboarding a new tenant has to be a
   one-line `kubectl apply`, not a runbook.
2. **Region.** It is not one region; it is three regions, active-active,
   because the customer is global and a region failure cannot be customer-
   visible for more than a few minutes.
3. **Identity.** It is not a shared HMAC; it is OIDC for humans and IRSA
   (or the GKE / AKS equivalent) for workloads, each verified by the mesh
   before downstream code sees a request.
4. **Delivery.** It is not a single Argo CD `Application`; it is an
   `ApplicationSet` fanning the platform across every regional cluster
   from a single source of truth.
5. **Data.** It is not one Postgres `StatefulSet`; it is a CloudNativePG
   cluster with a writer region and two streaming replicas, plus an outbox
   table to make payment events durable.
6. **ML.** It is not a rule-based recommender; it is a real loop —
   training Workflow at night, MLflow registry, KServe predictor with
   model canary, drift detector retraining on breach.
7. **Day-2.** It is not "the chapter ran"; it is a runbook the on-call
   engineer opens at 3am, a monthly chaos game-day, a quarterly DR drill,
   and a postmortem template.

Part 13 — twelve chapters — is the v2 platform that **actually has all
seven**, built as a sibling reference at
[`../examples/bookstore-platform/`](../examples/bookstore-platform/) so the
v1 Bookstore at [`../examples/bookstore/`](../examples/bookstore/) stays
exactly as Parts 00 - 12 left it (Helm 49, Kustomize 45 / 49 / 48, the
DB_DSN byte-identical) and the two can be read side by side. This chapter
opens that build. It is intentionally a brief — the eleven chapters that
follow each take ONE slice of the seven dimensions above and go deep; this
one establishes the contrast and the reading order.

> **In production:** The single biggest reason teams fail to migrate v1 to
> v2 is *trying to refactor v1 in place*. The 12-week pattern in the
> Production notes below ships v2 **alongside** v1, migrates capability by
> capability, and decommissions v1 last. Refactoring a live production
> Bookstore-shaped service into a multi-tenant, multi-region, real-auth
> platform without a parallel deploy is a multi-quarter scar-tissue
> exercise; building v2 next to it and cutting over is a multi-month one.

## Mental model

A **platform** is the ELEVEN models a v1 application chose not to have.
The gap between v1 and v2 is not a feature list; it is a discipline list
— each slice corresponds to a chapter, and the chapter answers one
question.

- **Tenancy model** ([13.02](02-tenancy-and-crossplane-onboarding.md)) —
  *who can run on the platform, and how do they get on?* v2 picks namespace-
  per-tenant + per-tenant cloud resources, expressed as a `BookstoreTenant`
  Crossplane Composition. Onboarding becomes one `kubectl apply` to a 15-
  line claim.
- **Regional model** ([13.03](03-multi-region-active-active.md)) — *what
  does "in production" mean when a region fails?* v2 runs three regions
  active-active; CloudNativePG handles cross-region replication; Argo CD
  ApplicationSet propagates the stack; DNS routes by latency and fails
  over.
- **Identity model** ([13.04](04-real-auth-keycloak-irsa-istio-jwt.md)) —
  *who is calling this API, and how do we trust them?* Two planes:
  Keycloak OIDC for humans, IRSA / Workload Identity for workloads, both
  verified at the Istio gateway.
- **Search and discovery model** (13.05, Phase 13b) — *how do users find
  books across millions of titles?* Meilisearch + Debezium CDC from
  Postgres. Per-tenant index isolation.
- **Payments and event-sourcing model** (13.06, Phase 13b) — *how do you
  take real money and survive partial failure?* Stripe sandbox + the
  outbox pattern + Kafka via Strimzi + idempotent payments-worker + saga
  compensation.
- **Edge model** (13.07, Phase 13b) — *what stands between the Internet and
  the platform?* Istio Gateway + Coraza WAF + per-tenant rate limiting.
- **ML model** (13.08, Phase 13b) — *how do you train, register, serve,
  detect drift on, and retrain a real model?* The full Argo Workflows ->
  MLflow -> KServe -> Alibi-Detect -> Argo Events loop.
- **Observability model** (13.09, Phase 13c) — *can you see what is
  happening?* OpenTelemetry traces + Tempo + Loki + Prometheus + Grafana,
  the full request flow tracked end-to-end.
- **Cost model** (13.10, Phase 13c) — *who is consuming what, and is the
  unit economics defensible?* OpenCost, per-tenant / per-region / per-
  workload-class. Budget alerts.
- **Developer model** (13.11, Phase 13c) — *how does a developer ship a
  new service on the platform without learning Crossplane / Argo CD /
  Istio?* Backstage scaffolder + software catalog + golden path.
- **Day-2 model** (13.12, Phase 13c) — *what does the on-call do when
  something breaks?* The runbook, the chaos game-day, the DR drill, the
  postmortem.

> The trap to keep in view: **v2 is not "v1 plus features"**. The v1
> Bookstore is already a working e-commerce app; you could add features to
> it indefinitely. v2 is **a different kind of artifact** — a platform — and
> the lesson of the chapters that follow is that the cost is in the
> eleven models above, not in any one of the features they support. The
> capability you gain from "real OIDC instead of toy JWT" is small; the
> capability you gain from having an identity *model* at all (humans vs
> workloads cleanly split; mesh-verified; rotatable; auditable) is the
> whole game.

## Threats and controls

The platform's threat model is in
[the Bookstore threat model](../examples/bookstore/THREAT-MODEL.md), and
[00.08](../00-foundations/08-security-foundations.md) defines the terms. This
chapter owns the cluster-wide boundary that every tenant inherits: the
namespaces, the platform roles and the admission level.

| Threat | Control taught here | Goes deeper in |
|---|---|---|
| A compromised container escalates to the node | Namespaces enforce `restricted`, so a non-compliant Pod is refused (Hands-on, section 2) | [05.02](../05-security/02-pod-security.md), [01.01 baseline](../01-core-workloads/01-pods.md#baseline) |
| A platform role reads or changes every tenant's Secrets | Platform roles ship as ClusterRoles with no bindings. The operator role's Secret access is an accepted finding in `.trivyignore.yaml` | [05.01](../05-security/01-authn-authz-rbac.md), [05.04](../05-security/04-secrets-and-cluster-hardening.md) |
| Break-glass access that outlives the incident | The admin role is cluster-admin in all but name, so it is bound only through the break-glass process | [13.12](12-day-2-runbook-on-call-dr-chaos.md) |
| A tenant reaches into another tenant's namespace | The tenant role is a ClusterRole that works only through a per-tenant RoleBinding | [13.02](02-tenancy-and-crossplane-onboarding.md) |

## Diagrams

### Diagram A — v1 vs v2 at the service-architecture level (Mermaid)

```mermaid
flowchart LR
    subgraph v1["BOOKSTORE v1 — single region, single tenant"]
      v1user(["User"])
      v1ing["Ingress<br/>(toy JWT)"]
      v1sf["storefront"]
      v1cat["catalog"]
      v1ord["orders"]
      v1pw["payments-worker"]
      v1pg[("postgres<br/>StatefulSet")]
      v1mq[["rabbitmq"]]
      v1user --> v1ing --> v1sf
      v1ing --> v1cat
      v1ing --> v1ord
      v1cat --> v1pg
      v1ord --> v1pg
      v1ord --> v1mq --> v1pw
    end

    subgraph v2["BOOKSTORE PLATFORM v2 — 3 regions, N tenants"]
      v2dns["Edge DNS<br/>(latency routing)"]

      subgraph reg1["region us-east (writer)"]
        v2gw1["Istio Gateway<br/>Coraza WAF<br/>JWT verify (Keycloak)"]
        v2sf1["storefront"]
        v2cat1["catalog"]
        v2ord1["orders"]
        v2pg1[("CNPG primary")]
        v2pgw1["payments-gateway<br/>(Stripe)"]
        v2ev1["events<br/>(Kafka)"]
        v2pw1["payments-worker"]
        v2rec1["recommendations<br/>(KServe)"]
      end

      subgraph reg2["region eu-west (reader)"]
        v2gw2["Istio Gateway"]
        v2cat2["catalog"]
        v2pg2[("CNPG standby")]
      end

      subgraph reg3["region ap-southeast (reader)"]
        v2gw3["Istio Gateway"]
        v2cat3["catalog"]
        v2pg3[("CNPG standby")]
      end

      v2dns --> v2gw1
      v2dns --> v2gw2
      v2dns --> v2gw3
      v2gw1 --> v2sf1
      v2gw1 --> v2cat1
      v2gw1 --> v2ord1
      v2cat1 --> v2pg1
      v2ord1 --> v2pg1
      v2ord1 --> v2pgw1 --> v2ev1 --> v2pw1
      v2cat1 --> v2rec1
      v2pg1 -.->|streaming replication| v2pg2
      v2pg1 -.->|streaming replication| v2pg3
    end

    v1user -. compare .- v2dns
```

### Diagram B — v1-vs-v2 capability matrix (ASCII)

```text
DIMENSION              BOOKSTORE v1                  BOOKSTORE PLATFORM v2
─────────────────────  ──────────────────────────    ────────────────────────────────────
Tenancy                single tenant                 N tenants (BookstoreTenant XR)
Onboarding             manual ns + RBAC + quota      one BookstoreTenant claim (13.02)
Region                 single region (kind)          3 regions active-active (13.03)
Data                   1 Postgres StatefulSet        CNPG primary + 2 streaming standbys
Cross-region failover  (none)                        promote standby + DNS flip
Auth — humans          shared-HMAC toy JWT           Keycloak OIDC, realm-per-tenant
Auth — workloads       (same JWT, kind hand-wave)    IRSA / Workload Identity (13.04)
Mesh JWT verify        (none)                        Istio RequestAuth + AuthZ (13.04)
Edge                   ingress-nginx                 Istio Gateway + Coraza WAF (13.07)
Rate limiting          (none)                        per-tenant Envoy local RL (13.07)
Search                 SQL LIKE                      Meilisearch + Debezium CDC (13.05)
Payments               RabbitMQ-only toy             Stripe sandbox + outbox + Kafka (13.06)
Event log              ephemeral RabbitMQ            Kafka topics (Strimzi); replayable
Recommender            rule-based                    KServe model + nightly retrain (13.08)
Drift detection        (none)                        Alibi-Detect + retrain on breach (13.08)
Tracing                (none)                        OTel + Tempo end-to-end (13.09)
Logging                stdout                        Loki, tenant-labelled (13.09)
Metrics                Prometheus + Grafana          + per-tenant dashboards (13.09)
Cost                   (none — single ns single tenant) OpenCost per-tenant/region (13.10)
Developer UX           kubectl apply by hand         Backstage scaffolder (13.11)
Day-2                  README                        runbook + DR drill + chaos (13.12)
GitOps                 one Application               ApplicationSet, Cluster generator
Hard invariant         Helm 49 / Kustomize 45/49/48  v1 invariants IMMUTABLE (v2 is additive-only)
```

## Hands-on with the Bookstore Platform

This chapter is the brief; no application workload lands yet. The hands-on
walks the [`examples/bookstore-platform/`](../examples/bookstore-platform/)
tree you will populate across Part 13 and stands up the three-region kind
topology that the rest of the part runs against.

The output shown in this chapter was captured on one kind cluster named
`sf-pilot` (Kubernetes v1.37.0), not on the clusters named here. That run did
not build the three regions, and it created its namespaces under prefixed names
so it could delete them afterwards. The commands below print the reader's names.
The [transcript](../examples/security-lab/evidence/13-01.txt) lists each
substitution in its header.

### 0. The platform tree, walked

From the guide repo root:

```sh
ls examples/bookstore-platform/
```

Illustrative listing, not captured. This chapter uses `clusters/`,
`platform-base/` and `kustomize/`; later chapters fill the others, as marked:

```text
README.md            ← platform overview, kind-runnable path, v1↔v2 thread
clusters/            ← three-region kind topology (13.01 / 13.03)
platform-base/       ← cluster-wide platform stack (namespaces, RBAC, priorities, Kueue)
kustomize/           ← base + per-region overlays
  base/
  regions/{us-east,eu-west,ap-southeast}/
argocd/              ← root ApplicationSet + Crossplane + Keycloak Applications
crossplane/          ← BookstoreTenant XRD + Composition + sample claim (13.02)
auth/                ← Keycloak realm + Istio RequestAuth + AuthZ + IRSA (13.04)
helm/                ← (Phase 13b) platform Helm umbrella chart
app/                 ← (Phase 13b) v2 service source
observability/       ← (Phase 13c)
cost/                ← (Phase 13c)
backstage/           ← (Phase 13c)
runbooks/            ← (Phase 13c)
```

Open the platform-level README:

```sh
cat examples/bookstore-platform/README.md
```

It states the v1-vs-v2 separation explicitly: the v1 Bookstore at
[`../bookstore/`](../examples/bookstore/) stays unchanged (the 49 / 45 / 49 /
48 invariants the rest of the guide depends on); v2 is a sibling reference
that may grow much larger without breaking those numbers.

### 1. Spin up the three-region kind topology

The platform runs as three regional clusters: `bookstore-platform-us-east`
(writer), `bookstore-platform-eu-west` (reader), and
`bookstore-platform-ap-southeast` (reader). The bootstrap script is
idempotent — re-run after `kind delete` and you get the same three clusters
back.

```sh
./examples/bookstore-platform/clusters/kind-3-region.sh
```

What it creates: three `kind` clusters, each with 1 control-plane + 2
workers, each carrying `topology.kubernetes.io/region` and
`bookstore-platform.example.com/role` node labels (`writer` for us-east,
`reader` for the other two). Distinct `apiServerPort`s (36443 / 36444 /
36445) so they coexist on one machine.

Confirm the contexts:

```sh
kubectl config get-contexts -o name | grep '^kind-bookstore-platform-'
```

Illustrative output, not captured. The captured run did not execute the
script, because it starts three kind clusters and the lab cluster is one:

```text
kind-bookstore-platform-us-east
kind-bookstore-platform-eu-west
kind-bookstore-platform-ap-southeast
```

### 2. Apply the platform-base into each region

Dry-run first, against your current context. The server runs validation and
admission on every object and creates nothing:

```sh
for f in 00-namespaces 01-rbac 02-priorityclasses; do
  kubectl apply --dry-run=server -f examples/bookstore-platform/platform-base/$f.yaml
done
```

<!-- gate: output -->
```text
namespace/bookstore-platform created (server dry run)
namespace/bookstore-platform-system created (server dry run)
namespace/bookstore-platform-ml created (server dry run)
clusterrole.rbac.authorization.k8s.io/bookstore-platform-admin created (server dry run)
clusterrole.rbac.authorization.k8s.io/bookstore-platform-operator created (server dry run)
clusterrole.rbac.authorization.k8s.io/bookstore-platform-tenant-admin created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-data created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-edge created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-critical created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-async created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-ml-serving created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-batch created (server dry run)
priorityclass.scheduling.k8s.io/bookstore-platform-ml-batch created (server dry run)
```

Then apply to each region:

```sh
for ctx in \
  kind-bookstore-platform-us-east \
  kind-bookstore-platform-eu-west \
  kind-bookstore-platform-ap-southeast
do
  echo "=== $ctx ==="
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/00-namespaces.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/01-rbac.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/02-priorityclasses.yaml
done
```

What landed in each cluster: three `bookstore-platform-*` namespaces (all
PSA `enforce: restricted`), three platform ClusterRoles
(`bookstore-platform-admin`, `-operator` and `-tenant-admin`), and seven
PriorityClasses (the platform priority ladder from data > edge > critical >
async > ml-serving > batch > ml-batch). The admin role is as strong as
cluster-admin, so bind it only through the break-glass process in 13.12. The
operator role reads every Secret, which is why `.trivyignore.yaml` records it
as an accepted finding. The tenant-admin role does nothing until a per-tenant
RoleBinding (13.02) gives it a namespace.

Verify with:

```sh
kubectl --context kind-bookstore-platform-us-east \
  get ns -l app.kubernetes.io/part-of=bookstore-platform \
  -L pod-security.kubernetes.io/enforce

kubectl --context kind-bookstore-platform-us-east \
  get clusterrole | grep bookstore-platform

kubectl --context kind-bookstore-platform-us-east \
  get priorityclass | grep bookstore-platform
```

The first command lists the three namespaces with `ENFORCE` set to
`restricted`. The other two list the ClusterRoles and PriorityClasses by name.

Now test the control. The next request is deliberate: a root container with
no `securityContext`, asked for in a `restricted` namespace. The API server
refuses it, and the refusal lists what is missing. `readOnlyRootFilesystem` is
not one of the [restricted checks](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted),
but the baseline asks for it anyway
([01.01](../01-core-workloads/01-pods.md#baseline)).

```sh
kubectl run probe-root --image=bookstore/catalog:dev --restart=Never \
  --dry-run=server -n bookstore-platform
```

<!-- gate: output -->
```text
Error from server (Forbidden): pods "probe-root" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "probe-root" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "probe-root" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "probe-root" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "probe-root" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 3. The kustomize render path (what Argo CD will apply)

The ApplicationSet you will use in [13.03](03-multi-region-active-active.md)
points each region's cluster at its matching overlay
(`examples/bookstore-platform/kustomize/regions/<REGION>`). Each overlay
inherits the base (the same 13 cluster-wide objects you just applied) and
adds a region label + a `cnpg-primary` annotation + a regional DNS-hostname
annotation. From the repo root:

```sh
for d in kustomize/base kustomize/regions/us-east kustomize/regions/eu-west kustomize/regions/ap-southeast; do
  kubectl kustomize examples/bookstore-platform/$d | grep -c '^kind:'
done
```

<!-- gate: output -->
```text
13
13
13
13
```

The 13 is by design: 3 namespaces + 3 ClusterRoles + 7 PriorityClasses. The
overlays don't change the object set — only labels and annotations. That is
the discipline: region overlays should be small.

### 4. Confirm v1 is still byte-identical (the "we didn't break the v1" check)

The v1 Bookstore at [`../examples/bookstore/`](../examples/bookstore/) is
explicitly out of scope for Part 13. The hard invariants the rest of the
guide leans on (Helm 49 / Kustomize 45 / 49 / 48 / `helm lint` zero-failed)
have to remain true after every Part 13 phase. Re-prove them:

```sh
helm lint examples/bookstore/helm/bookstore
```

<!-- gate: output -->
```text
==> Linting examples/bookstore/helm/bookstore
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

```sh
helm template examples/bookstore/helm/bookstore \
  | kubectl apply --dry-run=client -f - | grep -cE '(configured|created)'
```

<!-- gate: output -->
```text
49
```

```sh
for o in dev staging prod; do
  kubectl kustomize examples/bookstore/kustomize/overlays/$o | grep -c '^kind:'
done
```

<!-- gate: output -->
```text
45
49
48
```

If any of those numbers drift in your tree, the v1 invariant is broken;
back out whatever changed. The v2 tree is large; the v1 tree is fixed.

### 5. What is intentionally absent

You can `kubectl get pods -A | grep bookstore-platform-` and see **zero
pods**. That is correct. Phase 13a builds the *frame* the platform runs in;
the workloads land in Phase 13b. The next three chapters keep this
discipline:

- [13.02](02-tenancy-and-crossplane-onboarding.md) adds Crossplane + the
  `BookstoreTenant` Composition + the first sample tenant — still no app
  workloads, but the per-tenant namespace + RBAC + Quota + NetworkPolicy +
  Kueue queue exist after one `kubectl apply`.
- [13.03](03-multi-region-active-active.md) installs Argo CD on the
  management cluster, registers all three regions, applies the
  ApplicationSet, walks the DR drill (which on kind is `kind delete
  cluster --name bookstore-platform-us-east` + a documented promotion).
- [13.04](04-real-auth-keycloak-irsa-istio-jwt.md) installs Keycloak + Istio
  + applies the request-authentication / authorization-policy pair, with a
  curl test that proves 401 -> 200 once you have a valid token.

Phase 13b's first chapter (13.05) is the first place app workloads land.

> **In production:** Kind is the local stand-in for the real platform —
> the real platform is three managed Kubernetes clusters (EKS / GKE / AKS)
> in three real regions, each in its own VPC with cloud-managed control
> plane, real DNS, real cloud LB, and real cross-region streaming
> replication subject to real network latency. This phase's chapter
> hands-on sections cover the local path; each `## Production notes`
> section calls out what changes on the cloud path. There is no
> kind-vs-cloud feature flag in source — the YAML is the same; the
> environment is different.

## How it works under the hood

What "production-shape" actually means here is **discipline that carries
across every chapter**. Three pieces, each grounded in earlier Parts:

- **PSA `restricted` everywhere.** Every namespace the platform owns —
  cluster-wide `bookstore-platform-*` and per-tenant
  `bookstore-platform-<TENANT>`, carries three Pod Security Admission
  labels set to `restricted`: `enforce` refuses a non-compliant Pod, while
  `audit` and `warn` record and report one, so a regression shows up even
  where enforce is relaxed. Every Pod template the platform ships meets the
  [security baseline](../01-core-workloads/01-pods.md#baseline), whose fields
  01.01 explains, unless it is a registered exception. This is Part 05 ch.02
  carried to the platform layer. Each exception is registered in
  `security/namespace-exceptions.yaml` with its reason, its upstream source
  and an expiry.
- **Pinned-Helm installs into their own namespaces.** Every system operator
  (Crossplane, Keycloak, Istio, KServe, Strimzi, ESO, Tempo, Loki,
  OpenCost, Backstage, Chaos Mesh) installs via a pinned-version Helm
  chart into a dedicated namespace. **Never**
  `kubectl apply -f .../releases/latest/download/<PINNED-FILE>.yaml` (it
  404s when a release ships and silently breaks reproducibility); always
  `helm install … --version "$<TOOL>_CHART_VERSION"`. The
  [`../examples/bookstore-platform/argocd/`](../examples/bookstore-platform/argocd/)
  Applications encode this — `application-keycloak.yaml` pins
  `21.4.4`, `application-crossplane.yaml` pins `1.17.0`. The same lesson
  Part 07 ch.01 / ch.04 taught for the v1 Bookstore.
- **Signed images via cosign, supply-chain CI, and per-tenant cost.**
  Part 05 ch.03 introduced cosign and Kyverno `verifyImages`. The platform's
  CI signs every image at build time, and a Kyverno policy that refuses
  unsigned images ships as an optional Terraform module, off by default.
  Per-tenant cost is OpenCost (Phase 13c) labelled by the tenant label the
  Crossplane Composition stamps. Real SLOs that page (latency / availability /
  error-budget burn rate) are Part 06 ch.01 deepened in 13.09 —
  Alertmanager routes by tenant + region + severity, not "everyone gets
  the same page".

The v1 -> v2 gap is not these capabilities in isolation; v1 has every one
of them as a *chapter example*. The gap is **applying them all, uniformly,
with no exceptions, across every namespace, in every region, on every
pull request, on every deploy**. That is the production-shape discipline,
and it is what the rest of Part 13 demonstrates.

## Production notes

> **In production:** The 12-week migration plan for an existing v1-shape
> service to v2-shape is one of the most well-trodden paths in cloud-
> native operations. The pattern:
>
> | Week | Deliverable | Cutover risk |
> |------|-------------|--------------|
> | 1 - 2 | v2 platform stood up in a separate cluster; v1 stays in production untouched. | None — read-only build-out. |
> | 3 - 4 | Tenancy + identity wired (13.02 + 13.04). A test tenant onboarded; no real traffic. | None. |
> | 5 - 6 | Multi-region (13.03). v2 catalog read-only; serves a slice of read traffic via an explicit feature flag in v1's storefront. | Low — read-only mirror. |
> | 7 - 8 | Search + payments (13.05 + 13.06). Outbox starts shadowing v1's RabbitMQ; reconcile job verifies no event drops. | Medium — write-path is mirrored, not yet authoritative. |
> | 9 - 10 | ML loop (13.08). Recommender starts serving in shadow mode. Drift detector + retrain wired. | Low — recommender is non-blocking. |
> | 11 | Cutover plan: v2 becomes the writer; v1 reads from the shared CNPG. Stripe webhooks point at v2. Observability cross-confirms parity. | High — this is the cutover. |
> | 12 | Decommission v1. Postmortem. | Low — v2 has been authoritative for a week. |
>
> The "Big Bang" alternative — refactor v1 in place to v2 — typically
> stretches 6 - 9 months, ends mid-refactor with a hybrid that ships no
> features for a quarter, and leaves the team unable to roll back. The
> parallel-deploy + capability-by-capability migration is slower-feeling
> but durably finishes.

> **In production:** The **platform-team vs feature-team** boundary
> ([Part 11 ch.10](../11-advanced-production-patterns/10-platform-engineering.md))
> shows up here for real. Platform team owns `clusters/`, `platform-base/`,
> `crossplane/`, `argocd/`, `auth/`, `observability/`, `cost/`,
> `backstage/`. Feature team owns its tenant's `app/`. The
> `bookstore-platform-tenant-admin` ClusterRole in `01-rbac.yaml` is the
> binding surface: a feature-team identity (Keycloak group, OIDC group
> claim) bound to that ClusterRole inside its tenant ns gets control of the
> workloads and Services there, read access to its Secrets and
> NetworkPolicies, and nothing outside. That is the guardrail the Crossplane
> Composition enforces by construction; it is the same Part 11 ch.10
> "paved road" lesson scaled to a multi-tenant SaaS.

> **In production:** The honest cost of v2 vs v1, at the order of magnitude
> a real team should plan for:
>
> - **Compute.** Three regions multiply the compute floor. Karpenter /
>   Cluster Autoscaler (Part 10 ch.06) absorbs some of that via spot, but
>   stateful workloads keep a multi-region floor.
> - **Data egress.** Cross-region streaming replication and S3 cross-
>   region asset replication add egress charges that grow with real
>   traffic. Budget for it.
> - **Engineering time.** Supply-chain CI (signed images, SBOMs, policy
>   verification, admission webhooks) adds build time to every PR. Worth
>   it; budget for it.
> - **Operational time.** A three-region, multi-tenant platform needs a
>   team large enough to staff on-call and still ship. Below that, incidents
>   consume all capacity and no new capabilities ship.

> **In production:** Things v2 does NOT change from v1, and it is worth
> being clear about. The Bookstore application *code* is the same shape:
> a Go HTTP handler reading from Postgres still looks like a Go HTTP
> handler reading from Postgres. v2 wraps it in more boundaries (tenant ns
> + mesh + OIDC + outbox + observability), but the catalog service did
> not have to be rewritten in Rust to become "production". Resist
> rewrites that v2 doesn't demand.

## Quick Reference

```sh
# Spin up the three-region local topology (Phase 13a hands-on)
./examples/bookstore-platform/clusters/kind-3-region.sh

# Apply the platform-base into each region
for ctx in \
  kind-bookstore-platform-us-east \
  kind-bookstore-platform-eu-west \
  kind-bookstore-platform-ap-southeast
do
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/00-namespaces.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/01-rbac.yaml
  kubectl --context "$ctx" apply -f examples/bookstore-platform/platform-base/02-priorityclasses.yaml
done

# Render the per-region overlay (what Argo CD will apply once 13.03 wires it)
kubectl kustomize examples/bookstore-platform/kustomize/regions/us-east

# Re-prove v1 invariants (after every Part 13 phase)
helm lint examples/bookstore/helm/bookstore
helm template examples/bookstore/helm/bookstore \
  | kubectl apply --dry-run=client -f - | grep -cE '(configured|created)'   # 49
kubectl kustomize examples/bookstore/kustomize/overlays/dev     | grep -c '^kind:'   # 45
kubectl kustomize examples/bookstore/kustomize/overlays/staging | grep -c '^kind:'   # 49
kubectl kustomize examples/bookstore/kustomize/overlays/prod    | grep -c '^kind:'   # 48
```

The root ApplicationSet that applies this stack to each region is in
[`../examples/bookstore-platform/argocd/applicationset-platform.yaml`](../examples/bookstore-platform/argocd/applicationset-platform.yaml);
13.03 walks through it.

Readiness checklist (Phase 13a complete when all four are yes):

- [ ] Three `kind-bookstore-platform-*` contexts exist (`kubectl config
      get-contexts | grep bookstore-platform`).
- [ ] Each region renders the platform-base kustomize overlay to 13 objects
      (`kubectl kustomize examples/bookstore-platform/kustomize/regions/<REGION> | grep -c '^kind:'`).
- [ ] `helm lint examples/bookstore/helm/bookstore` reports 0 failed and
      the helm template still produces 49 objects (v1 invariant intact).
- [ ] The chapter files 13.02 to 13.04 exist in
      `13-grand-capstone-bookstore-platform/`.

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Name three things that make Bookstore v2 a "different artifact" rather than "v1 with more features."**
   <details><summary>Show answer</summary>

   (1) **Multi-tenancy** — v1 is single-tenant in one namespace; v2 is N tenants, each with their own data, identity, quotas, and dashboards. Adding a "tenant_id" column to v1's tables wouldn't fix the cross-tenant access, identity, cost-allocation, or blast-radius story. (2) **Multi-region active-active** — v1 runs in one cluster; v2 runs in three regions with cross-region Postgres replication, DNS failover, and an SLO that survives region loss. (3) **Real auth + edge + observability + ML loop + payments-with-saga + cost-visibility** — each of these is a chapter's worth of new infrastructure, not a code change. The total surface is qualitatively bigger and operationally different.

   </details>

2. **The chapter argues v1's "small-on-purpose shape" is right for some teams. When is that?**
   <details><summary>Show answer</summary>

   When (a) you have one customer or one team, (b) you don't have regulatory pressure for data residency or audit, (c) the cost of one region's downtime is acceptable, (d) you have a small engineering team that can't sustain the operational burden of v2's infrastructure. v1 is the right *learning* artifact and a legitimate *production* shape for many startups. The mistake is building v2's complexity preemptively — sometimes called "premature platform" — before the org has the scale or pain to justify it. Build v1 first; let real pain pull you toward v2.

   </details>

3. **Map each Part 13 chapter to one of the seven v2 dimensions (tenancy, region, identity, search, payments, edge, ML, ops).**
   <details><summary>Show answer</summary>

   ch.02 → tenancy. ch.03 → region. ch.04 → identity. ch.05 → search. ch.06 → payments. ch.07 → edge. ch.08 → ML. ch.09 → ops (observability). ch.10 → ops (cost). ch.11 → ops (developer portal). ch.12 → ops (day-2). The mapping shows ops is the largest dimension because each capability needs an operational story — dashboards, on-call, runbook, DR drill, cost-attribution — beyond the capability itself.

   </details>

4. **Hands-on: render the `bookstore-platform` kustomize overlay for one region and count the objects. Compare to v1's 49. What's the rough delta and what does it tell you?**
   <details><summary>What you should see</summary>

   v2 has far more objects per region than the 13 here, and the count grows with each chapter's infrastructure: Crossplane XRDs, ApplicationSets, Istio Gateway + WAF, Keycloak, Strimzi Kafka, MLflow, KServe, Backstage, OpenCost. The delta tells you (a) v2 is structurally larger and (b) most new objects are CRDs from operators, so the cluster's "API surface" has grown, not just its workload count. This is platform engineering: more objects, but each managed by an operator the platform team owns.

   </details>

5. **A feature team's Deployment is refused in its `bookstore-platform-<TENANT>`
   namespace with a PodSecurity error. What do you change, and what do you leave
   alone?**
   <details><summary>Show answer</summary>

   Change the workload until it meets the baseline: a non-root `runAsUser`,
   `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`,
   `capabilities.drop: ["ALL"]`, and an `emptyDir` for each writable path.
   Leave the namespace's `enforce` label alone. Relaxing it moves the risk onto
   every Pod in that namespace. If a workload truly needs more, it needs a
   registered exception with a reason, an upstream source and an expiry, reviewed
   like any other change.

   </details>

## Further reading

- Official: **Pod Security Admission**,
  <https://kubernetes.io/docs/concepts/security/pod-security-admission/>, and
  **RBAC good practices**,
  <https://kubernetes.io/docs/concepts/security/rbac-good-practices/>. The
  controls in this chapter rest on both.
- **Rosso et al., _Production Kubernetes_, ch.6 — "Application Cluster
  Topology"** and **ch.16 — "Platform Abstractions"** — the cluster-as-
  product pattern this part scales up to multi-tenant SaaS, and the
  guardrail-by-construction discipline 13.02 onward enforces.
- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Service Discovery* (ch.13)**
  and **_Sidecar_ (ch.16)** — the pattern vocabulary the multi-service,
  mesh-enrolled v2 platform speaks in.
- Official: **Google Cloud Architecture Center — _Multi-region application
  architecture_** <https://cloud.google.com/architecture/multi-region-app-architecture>;
  **Kubernetes Multi-tenancy WG documentation**
  <https://github.com/kubernetes-sigs/multi-tenancy>; the **Team Topologies
  book site** <https://teamtopologies.com/key-concepts> for the
  platform-team-vs-stream-team boundary.
