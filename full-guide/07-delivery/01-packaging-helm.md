# 01 — Packaging with Helm

> Why a raw `kubectl apply -f` directory does not scale to multiple
> environments and release lifecycles; **Helm 3** architecture (no Tiller; the
> release stored in an in-cluster Secret; revisions/history/rollback); chart
> anatomy (`Chart.yaml`, `values.yaml`, `templates/`, `_helpers.tpl`,
> `NOTES.txt`, `charts/`, `crds/`); Go templating + Sprig +
> `include`/`tpl`/`required`/`default`/`toYaml`; values precedence &
> `values.schema.json`; hooks and the migration-Job-as-hook pattern; library
> vs application charts and dependency management — applied by packaging the
> **entire** cumulative Bookstore (Parts 00–06) as one real chart that renders
> the same app as `raw-manifests/`, restricted-PSA and all.

**Estimated time:** ~30 min read · ~90 min hands-on
**Prerequisites:** [Part 00 ch.06](../00-foundations/06-declarative-api-model.md) — the declarative manifests Helm renders · [Part 03 ch.01](../03-config-and-storage/01-configmaps.md) — values as the input layer over manifests · [Part 05 ch.02](../05-security/02-pod-security.md) — `restricted` PSA invariants Helm must preserve
**You'll know after this:** • explain Helm 3 (no Tiller; releases stored as in-cluster Secrets) and revision/rollback semantics · • lay out a chart with `Chart.yaml`, `values.yaml`, `templates/`, `_helpers.tpl` and `NOTES.txt` · • write Go templating with Sprig, `include`, `tpl`, `required`, `default` and `toYaml` · • use Helm hooks for the migration-Job pattern and decide library vs application charts · • render the 49-object Bookstore as a Helm chart, and keep its values from weakening the baseline

<!-- tags: helm, platform-engineering, gitops, ci-cd -->

## Why this exists

By the end of Part 06 the Bookstore is **~29 raw manifests** in
[`examples/bookstore/raw-manifests/`](../examples/bookstore/raw-manifests/),
applied with an ordered pile of `kubectl apply -f` commands. That worked while
we were *teaching* one primitive per chapter. It does not survive contact with
**delivery**, where four pressures appear at once:

1. **Many environments, one app.** dev wants 1 replica and debug logging;
   staging wants prod's shape at half scale; prod wants 4 replicas, real
   registry images, and the demo Secret *gone*. With raw YAML you either keep
   N copies of every file (they drift within a week) or hand-`sed` them (the
   "templating with `sed`" anti-pattern — quoting bugs, no validation, no
   record of what you actually applied).
2. **A release is a unit, not 29 files.** "Roll the whole app back to what we
   ran before the 14:00 deploy" has no answer when the truth is "whatever
   sequence of `kubectl apply` someone ran". You need an atomic, versioned,
   *named* release with history.
3. **Ordering and lifecycle.** The schema migration must run **after** Postgres
   exists, **every** deploy, idempotently. `kubectl apply -f .` has no
   "do this, wait, then that" — we faked it with manual `kubectl wait`.
4. **Discoverability.** "What can I tune without editing manifests?" has no
   answer in raw YAML. A consumer must read every file.

**Helm** is the package manager that addresses all four: a **chart** is a
parameterised, versioned bundle; `helm install` renders it with your
**values** and records the result as a **release** with **revisions** you can
`helm history`/`helm rollback`; **hooks** give lifecycle ordering; `values.yaml`
+ `values.schema.json` are the documented, validated tuning surface. This
chapter packages the *exact same Bookstore* — every restricted
`securityContext`, the Part 04 scheduling layer, the byte-identical
`catalog`/`orders` `DB_DSN`, the PSA-`restricted` namespace — as
[`examples/bookstore/helm/bookstore/`](../examples/bookstore/helm/bookstore/),
and proves the rendered output is logically equivalent to the raw manifests.
[ch.02](02-packaging-kustomize.md) does the same with Kustomize and contrasts
the two. [ch.04](04-gitops-argocd.md) has Argo CD reconcile the ch.02 overlays
from Git. Argo CD can also take this chart as an Application source, but this
guide does not wire that up.

## Mental model

**Helm is a templating + release-management layer that sits *beside*
`kubectl`, not inside the cluster.**

- **Chart** = a directory of **templates** (Go-templated Kubernetes YAML) +
  **`values.yaml`** (the defaults) + **`Chart.yaml`** (metadata/version). It is
  inert text until rendered.
- **`helm install <NAME> <CHART> -f my-values.yaml`** = *render the templates
  with (chart defaults ← `-f` files ← `--set` flags), then `apply` the
  resulting objects to the API server, then store the rendered manifest +
  the values + a revision number as a **release**.*
- **The release lives in the cluster as a Secret** (type
  `helm.sh/release.v1`, base64+gzip), in the release's namespace. There is
  **no server-side component** — Helm 3 deleted Tiller (the Helm 2 in-cluster
  daemon that was a notorious cluster-admin backdoor). `helm` is a *client*;
  the cluster just sees normal `kubectl`-style API calls plus that one
  bookkeeping Secret.
- **Every `helm upgrade` makes a new revision.** `helm history` lists them;
  `helm rollback <NAME> <REV>` re-applies an old revision's manifest. This is
  the atomic "the whole app, as a unit" that raw `kubectl` lacked.
- **Templating is Go `text/template` + the Sprig function library**, with
  Helm's own helpers (`include`, `required`, `tpl`, `.Files`, `.Release`,
  `.Capabilities`). `_helpers.tpl` holds **named templates** so repeated YAML
  (labels, the restricted `securityContext`, the DSN) is written **once** and
  cannot drift — that is the single most important idea for keeping this chart
  faithful to `raw-manifests/`.

The trap to keep in view (covered in *When Helm hurts*): templating is just
string substitution, so a chart *can* become unreadable conditionals — "YAML
with extra steps". The discipline is: parameterise what genuinely varies,
keep the invariant security/scheduling model in helpers, and never let a value
toggle make the app *insecure by default*.

## Threats and controls

| Threat | Control in this chapter | Deeper |
|---|---|---|
| A value switches off a baseline field, such as `allowPrivilegeEscalation: true` or a writable root filesystem | `values.schema.json` fixes the baseline fields of every `securityProfiles` entry, so the render refuses the value | [05.02](../05-security/02-pod-security.md) for the fields; [07.02](02-packaging-kustomize.md) for overlays |
| A password in a values file or in the release record | Prod sets `dbCredentials.create: false`; the Secret comes from outside the chart | [03.02](../03-config-and-storage/02-secrets.md) |
| A default credential in the production path, such as a stock login in a connection Secret | The chart holds no KEDA connection string and renders no Secret for it; `keda.enabled=true` without `keda.connectionSecretName` fails the render | [03.02](../03-config-and-storage/02-secrets.md), [11.05](../11-advanced-production-patterns/05-secrets-at-scale.md) |
| A chart or image other than the one you reviewed | Pin the chart by digest, check a signature when the publisher makes one, render and scan before install | [05.03](../05-security/03-supply-chain.md); [07.03](03-cicd-pipeline.md) for signing in CI |

## Diagrams

### `helm install` flow: chart + values → render → release Secret → API → revision (Mermaid)

This chart's actual lifecycle: it has **no** pre-install hook (only the
`db-migrate` post-install/post-upgrade hook), so the flow is render → apply
the normal objects → run post-* hooks → write the release Secret. (If a chart
*did* declare a pre-install hook, Helm would apply it between render and the
normal objects, waiting for it first — the dashed node below shows where that
would slot in for a chart that has one; this chart skips it.)

```mermaid
flowchart TD
    chart["Chart on disk<br/>templates/ + values.yaml<br/>+ Chart.yaml + _helpers.tpl"]
    vals["User values<br/>-f values-prod.yaml<br/>--set image.tag=1.0.0"]
    merge["Merge values<br/>chart defaults &lt; -f files &lt; --set<br/>(values.schema.json validated)"]
    render["Render Go templates + Sprig<br/>include/tpl/required/default<br/>→ one multi-doc YAML stream"]
    prehook["(only if a chart has them)<br/>pre-install hooks fire here<br/>— this chart has NONE"]
    apply["Apply all normal release objects<br/>(incl. postgres StatefulSet)<br/>to kube-apiserver<br/>(admission incl. PodSecurity)"]
    hookpost["Then post-install/post-upgrade hooks<br/>(db-migrate Job) — AFTER all normal<br/>objects, by lifecycle event; Helm waits"]
    rel["Write release Secret<br/>helm.sh/release.v1<br/>(manifest+values, revision N)"]
    hist["helm history / status<br/>helm rollback N-1<br/>re-applies revision N-1"]

    chart --> merge
    vals --> merge
    merge --> render
    render -. "(none in this chart)" .-> prehook
    render --> apply --> hookpost --> rel --> hist
```

### Chart directory tree (ASCII)

```
 examples/bookstore/helm/bookstore/
 ├── Chart.yaml              apiVersion v2, type application, version/appVersion,
 │                           kubeVersion ">=1.30.0-0" (no dependencies — see below)
 ├── values.yaml             ALL defaults; reproduces raw-manifests exactly
 ├── values.schema.json      JSON Schema: toggles, image blocks, securityProfiles
 ├── values-dev.yaml         per-env overrides (1 replica, debug, no HPA/PDB)
 ├── values-staging.yaml     prod shape, half scale, SM/PR on
 ├── values-prod.yaml        4 replicas, registry images, demo Secret OFF
 ├── .helmignore             package-time excludes
 ├── README.md               values table + the CRD-toggle prereqs
 └── templates/
     ├── _helpers.tpl        named templates: labels, the restricted SC per
     │                       image, the SINGLE DB_DSN, ingress-XOR-gateway guard
     ├── 00-namespace.yaml   ns + PSA restricted labels + ResourceQuota/LimitRange
     ├── 05-serviceaccounts-rbac.yaml   8 SAs (automount:false) + catalog Role
     ├── 10..14, 19          catalog/storefront/redis/rabbitmq/orders/pay-worker
     ├── 20-postgres-statefulset.yaml   headless Svc + StatefulSet + VCT
     ├── 21-db-migrate-job.yaml         Job as a post-install/upgrade HOOK
     ├── 22-cleanup-cronjob.yaml        CronJob (normal release object)
     ├── 30-catalog-canary.yaml         toggle (XOR catalog)
     ├── 35-priorityclasses.yaml        cluster-scoped, resource-policy: keep
     ├── 40-services.yaml / 50-ingress.yaml / 51-gateway.yaml (ingress XOR gw)
     ├── 60-networkpolicy.yaml          all 10 policies
     ├── 70/80/81/83/18      CRD-backed: kyverno/SM/PR/KEDA/snapshot (toggles OFF)
     ├── 82-hpa-catalog.yaml / 84-pdb.yaml   built-in (toggles ON)
     └── NOTES.txt           post-install guidance + the demo-Secret warning
 (crds/ — Helm's special CRD dir — is intentionally NOT used here; see
  "How it works under the hood" for why the CRD objects are toggled instead.)
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** All `helm`
and `kubectl` commands below are run from there; chart paths are relative to
it. This chapter does **not** modify `raw-manifests/` — it introduces the
parallel [`examples/bookstore/helm/bookstore/`](../examples/bookstore/helm/bookstore/)
chart and operates it.

We will: (0) install Helm + a clean kind cluster + the four images; (1) `helm
lint`/`template` and read the render; (2) create a PSA-labelled namespace and
`helm install` into it; (3) inspect the release
(`list`/`status`/`get manifest`/`history`); (4) a values override + `helm
upgrade` + `helm rollback`; (5) prove restricted admission with a server
dry-run; (6) toggle a CRD-backed extra and see the honest "needs an operator"
behaviour.

### 0. Prerequisites — Helm, a fresh cluster, the images (self-bootstrapping)

`helm` is a single static binary; install it once
([helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/)):

```sh
# Linux, amd64. This guide pins Helm v3.22.1. On macOS use shasum -a 256 -c.
curl -fsSLO https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v3.22.1-linux-amd64.tar.gz.sha256sum
sha256sum -c helm-v3.22.1-linux-amd64.tar.gz.sha256sum
tar -xzf helm-v3.22.1-linux-amd64.tar.gz linux-amd64/helm
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
#  or: go install helm.sh/helm/v3/cmd/helm@v3.22.1
helm version
```

> **Which Helm?** This chapter pins **Helm v3.22.1**, the patch release of the
> last Helm 3 minor line (v3.22.x). Helm 3 gets security fixes only until
> **February 10, 2027**, and no Helm 3 release of any kind after that date
> ([Helm 3 end of life](https://helm.sh/blog/helm-v3-end-of-life), June 2,
> 2026). Plan the move to Helm 4 before then, and test these commands on
> Helm 4 before you rely on them.

A clean local cluster + the four Bookstore images loaded (the same
self-bootstrap as every prior chapter; the chart pulls `postgres:16`,
`redis:7`, `rabbitmq:3.13-management` from the registry — only the four
`bookstore/*:dev` images are `kind load`ed):

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore
kubectl cluster-info

# Build + load the four app images (full instructions: examples/bookstore/app/README.md)
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done
```

> **Self-bootstrapping note.** After any `kind delete && kind create` you must
> re-`kind load` the four images and re-run the namespace and `helm install`
> steps below. A fresh cluster has neither. Unlike the raw-manifests chapters, there is **no
> `kubectl apply` chain to replay**: a single `helm install` creates the
> namespace (PSA-labelled), every object, and runs the migration hook. That
> consolidation is the point of this chapter.

### 1. Lint and render — read what Helm will apply

`helm lint` checks chart structure/templates without a cluster:

```sh
helm lint examples/bookstore/helm/bookstore
```

<!-- gate: output -->
```text
==> Linting examples/bookstore/helm/bookstore
[INFO] Chart.yaml: icon is recommended
# ...
1 chart(s) linted, 0 chart(s) failed
```

`0 chart(s) failed`. The single `[INFO]` is cosmetic (a chart `icon:` URL is
recommended for chart-repo UIs; irrelevant for a guide chart) — INFO is not a
failure or even a warning.

`helm template` renders the chart locally (no cluster, no release) so you can
**read exactly what would be applied** — the habit that keeps templating
honest:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | less
```

Sanity-check it against the API server **without applying** (client dry-run):

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  | kubectl apply --dry-run=client -f - 2>&1 | grep -c "created (dry run)"
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  | kubectl apply --dry-run=client -f - 2>&1 | grep -c "no matches for kind"
```

On an empty cluster all 49 objects report `created (dry run)`. The lab cluster
already held the three `bookstore-*` PriorityClasses from an earlier run, so
its count was 46 and those three reported `configured (dry run)`. Its count of
`no matches for kind` was 0. The lab output in this chapter came from a cluster
with a different name, and the transcript records that substitution.

That zero is by design: every CRD-backed object (ServiceMonitor,
PrometheusRule, KEDA `ScaledObject`, Gateway, Kyverno `ClusterPolicy`,
VolumeSnapshot) is behind a value toggle that defaults **off** where the CRD
is not built into Kubernetes, so a plain render is 100% built-in API kinds.

### 1a. Values the schema refuses

Helm merges the chart's values, then each `-f` file, then each `--set`, so any
of them can change a field. The chart's `values.schema.json` fixes the baseline
fields in every `securityProfiles` entry: `runAsNonRoot: true`, `runAsUser` of
at least 1, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
`capabilities.drop` containing `ALL`, and the `RuntimeDefault` seccomp profile.
It also refuses any field it does not list, so `privileged` and
`capabilities.add` are refused. It pins the namespace's Pod Security level to
`restricted` and keeps the NetworkPolicy on. Helm validates the values before
it renders, so a refused value stops the command and nothing is produced:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set securityProfiles.goService.container.allowPrivilegeEscalation=true 2>&1 | tail -n 3
```

<!-- gate: output -->
```text
bookstore:
- at '/securityProfiles/goService/container/allowPrivilegeEscalation': value must be false
```

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set securityProfiles.goService.container.privileged=true | head -n 3
```

<!-- gate: output -->
```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
bookstore:
- at '/securityProfiles/goService/container': additional properties 'privileged' not allowed
```

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set 'securityProfiles.goService.container.capabilities.add[0]=SYS_ADMIN' | head -n 3
```

<!-- gate: output -->
```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
bookstore:
- at '/securityProfiles/goService/container/capabilities/add': maxItems: got 1, want 0
```

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.psa.enforce=privileged | head -n 3
```

<!-- gate: output -->
```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
bookstore:
- at '/namespace/psa/enforce': value must be 'restricted'
```

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set networkPolicy.enabled=false | head -n 3
```

<!-- gate: output -->
```text
Error: values don't meet the specifications of the schema(s) in the following chart(s):
bookstore:
- at '/networkPolicy/enabled': value must be true
```

The schema is not a complete policy. The Kyverno action is `Audit` on purpose
(see the toggles below), so the schema does not pin it.

`readOnlyRootFilesystem=false` and `runAsUser=0` fail the same way. A workload
that needs a writable path gets an `emptyDir` mounted at that path, as the
baseline's `/tmp` mount does, not a looser profile.

### 1b. Pin a chart you did not write, and check it first

A third-party chart is someone else's code running with your cluster rights:
its templates decide what gets applied, and its hooks run Jobs during install.
Pin the exact artifact, check its signature if the publisher makes one, and
read the render before you install. The example here is the Argo CD chart,
which [07.04](04-gitops-argocd.md) installs.

Read the version and the digest that the registry serves for it:

```sh
helm show chart oci://ghcr.io/argoproj/argo-helm/argo-cd --version 10.11.6 | grep -E '^(version|appVersion):'
```

<!-- gate: output -->
```text
Pulled: ghcr.io/argoproj/argo-helm/argo-cd:10.11.6
Digest: sha256:90f462a0695121f65a71cd053619f80023b4efef6bc211f750ffcaaa1628b5b6
appVersion: v3.5.6
version: 10.11.6
```

From now on, name the chart by that digest, as in
`oci://ghcr.io/argoproj/argo-helm/argo-cd@sha256:90f4...`. A digest cannot be
moved the way a tag can, so the artifact you reviewed is the one that installs. Helm accepts the digest form in `helm show` and
`helm template`.

Check for a signature. On the day of the captured run, cosign found none for
this digest under the publisher's GitHub Actions identity:

```sh
cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'https://github.com/argoproj/argo-helm/.*' \
  ghcr.io/argoproj/argo-helm/argo-cd@sha256:90f462a0695121f65a71cd053619f80023b4efef6bc211f750ffcaaa1628b5b6
```

<!-- gate: output -->
```text
Error: no signatures found
error during command execution: no signatures found
```

A missing signature is a fact to record, not a pass. The digest pin and the
render review are then the checks you have. The regular expression in the
example accepts a signature from any workflow and any ref under the publisher's
repository, so it is a first look and not a check. When a publisher does sign,
pin the full identity with `--certificate-identity` set to the workflow path
and the ref that the publisher's own documentation names, and keep the
verification in your review record. This guide does not state that identity,
because the captured run found no signature to read it from.

Render the chart to a file, count its objects and scan the render. Helm
renders with the chart's default values here; a real install uses your values.

```sh
mkdir -p review
helm template argo-cd oci://ghcr.io/argoproj/argo-helm/argo-cd@sha256:90f462a0695121f65a71cd053619f80023b4efef6bc211f750ffcaaa1628b5b6 \
  -n argocd > review/argo-cd.yaml
grep -c "^kind:" review/argo-cd.yaml
trivy config --quiet --severity HIGH,CRITICAL review | grep -E "^(Total|Failures|review/)|Tests:"
```

<!-- gate: output -->
```text
59
```

<!-- gate: output -->
```text
Tests: 47 (SUCCESSES: 35, FAILURES: 12)
Failures: 12 (HIGH: 7, CRITICAL: 5)
```

Twelve checks fail at HIGH or CRITICAL on the defaults. A scan is a review
queue, not a verdict: for each failure, fix it in values, record an exception
with its reason and an expiry, or do not install. Hooks are rendered too, so
search the render for `helm.sh/hook` before you install. `helm template` runs
no workload, but `helm install` will run every hook it finds.

### 2. Create the namespace, then install the release

The chart renders a `Namespace` object, so `helm template` shows the whole app
(49 objects). `helm install` cannot use that object. Helm stores its release
record in the release namespace before it applies anything, so the namespace
must already exist, and `--create-namespace` then collides with the chart's own
`Namespace` (Helm reports `namespaces "bookstore" already exists`). Create the
namespace yourself with the Pod Security labels, and install with
`namespace.create=false`. The ResourceQuota and LimitRange are rendered either
way. Installing into a namespace that does not exist fails with
`namespaces "bookstore" not found`, for the same reason.

```sh
kubectl create namespace bookstore
kubectl label namespace bookstore \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
helm install bookstore examples/bookstore/helm/bookstore \
  -n bookstore --set namespace.create=false --wait
```

Every later `helm upgrade` in this chapter repeats
`--set namespace.create=false`. A value that is not passed falls back to the chart default, which is `true`,
and the upgrade would then try to create the Namespace again.

`--wait` holds the command until the normal objects are Ready and the
post-install `db-migrate` hook Job has completed, so the inspections below see
a finished migration. Without `--wait` the command returns at once and the hook
Job may still be running. Helm then prints the rendered `NOTES.txt`: what was
created, how to reach it, the CRD-toggle reminders and the demo-Secret warning.

The captured runs in sections 2 to 6 used the namespace `p07-finish-helm` on a
shared lab cluster, and a values file that points the three hostnames the chart
builds from `bookstore` at that namespace. Where your run shows `bookstore`, the
capture shows `p07-finish-helm`. Those runs came before the broker URL moved
into the `db-credentials` Secret. The third hostname was the payments-worker's
`paymentsWorker.amqpUrl`, a value the chart no longer has: the URL now names the
Service without a namespace, so the chart builds two hostnames from `bookstore`,
and the `helm get values` capture below still lists the retired value. The top
of the install output:

<!-- gate: output -->
```text
NAME: bookstore
# ...
NAMESPACE: p07-finish-helm
STATUS: deployed
REVISION: 1
```

Watch it converge:

```sh
kubectl get pods -n bookstore
```

<!-- gate: output -->
```text
NAME                               READY   STATUS    RESTARTS   AGE
catalog-65b9c66f6d-2dbhn           1/1     Running   0          4m19s
catalog-65b9c66f6d-9sg97           1/1     Running   0          4m19s
catalog-65b9c66f6d-t9v6c           1/1     Running   0          4m19s
orders-7f4d49848c-n6tzm            1/1     Running   0          4m19s
orders-7f4d49848c-rdxsm            1/1     Running   0          4m19s
payments-worker-84bdc645d5-qfrrc   1/1     Running   0          4m19s
postgres-0                         1/1     Running   0          4m18s
rabbitmq-5d4d4759f4-zb8w4          1/1     Running   0          4m19s
redis-7886bf6bbb-tnwnl             1/1     Running   0          4m19s
storefront-5d4785446f-dz5rr        1/1     Running   0          4m19s
storefront-5d4785446f-n2wzt        1/1     Running   0          4m19s
```

All eleven pods are `Running`, so admission accepted every workload under
`enforce: restricted`. Confirm the labels that did the enforcing:

```sh
kubectl get ns bookstore -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security
```

<!-- gate: output -->
```text
"pod-security.kubernetes.io/audit":"restricted"
"pod-security.kubernetes.io/enforce":"restricted"
"pod-security.kubernetes.io/warn":"restricted"}
```

The migration Job is the post-install hook. Ask for it:

```sh
kubectl get job db-migrate -n bookstore
```

<!-- gate: output -->
```text
Error from server (NotFound): jobs.batch "db-migrate" not found
```

It is gone on purpose. The Job's `helm.sh/hook-delete-policy` includes
`hook-succeeded`, so Helm deletes a hook Job once it completes and keeps only a
failed one for debugging. A missing Job after a good install is the expected
result. Its events show that it ran, and the database holds the tables it
created (`cut` only narrows the event lines):

```sh
kubectl get events -n bookstore --field-selector involvedObject.name=db-migrate | cut -c1-90
```

<!-- gate: output -->
```text
LAST SEEN   TYPE     REASON             OBJECT           MESSAGE
14s         Normal   SuccessfulCreate   job/db-migrate   Created pod: db-migrate-l9rtd
1s          Normal   Completed          job/db-migrate   Job completed
```

```sh
kubectl exec -n bookstore postgres-0 -- psql -U bookstore -d bookstore -c '\dt'
```

<!-- gate: output -->
```text
          List of relations
 Schema |  Name  | Type  |   Owner   
--------+--------+-------+-----------
 public | books  | table | bookstore
 public | orders | table | bookstore
(2 rows)
```

### 3. Inspect the release (the thing raw `kubectl` never gave us)

```sh
helm list -n bookstore
```

<!-- gate: output -->
```text
NAME        NAMESPACE       REVISION    UPDATED                                 STATUS      CHART           APP VERSION
bookstore   p07-finish-helm 1           2026-10-31 10:51:47.804924 +0500 PKT    deployed    bookstore-0.1.1 dev        
```

```sh
helm status bookstore -n bookstore | head -n 6
```

<!-- gate: output -->
```text
NAME: bookstore
LAST DEPLOYED: Sat Oct 31 10:51:47 2026
NAMESPACE: p07-finish-helm
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

`helm status` goes on to print the rendered notes. `helm get manifest` returns
the exact YAML that was applied. Count its objects:

```sh
helm get manifest bookstore -n bookstore | grep -c "^kind:"
```

<!-- gate: output -->
```text
44
```

That is 44, not the 49 of `helm template`. This install left out the Namespace
(`namespace.create=false`) and the three PriorityClasses
(`priorityClasses.create=false`, because the shared lab cluster already had
them), and Helm keeps a hook Job out of the release manifest. On a fresh
cluster, where `priorityClasses.create` stays `true`, the count is 47.

`helm get values` returns only the values you supplied, not the chart defaults.
Here that is `namespace.create=false` and the lab's substitutions:

```sh
helm get values bookstore -n bookstore
```

<!-- gate: output -->
```text
USER-SUPPLIED VALUES:
catalogConfig:
  data:
    REDIS_ADDR: redis:6379
database:
  host: postgres
namespace:
  create: false
  name: p07-finish-helm
paymentsWorker:
  amqpUrl: amqp://guest:guest@rabbitmq:5672/
priorityClasses:
  create: false
```

```sh
helm history bookstore -n bookstore
```

<!-- gate: output -->
```text
REVISION    UPDATED                     STATUS      CHART           APP VERSION DESCRIPTION     
1           Sat Oct 31 10:51:47 2026    deployed    bookstore-0.1.1 dev         Install complete
```

`helm get manifest` reads the release **Secret**, not the cluster. The release
is stored in-cluster, with no Tiller, as one Secret per revision:

```sh
kubectl get secret -n bookstore -l owner=helm
```

<!-- gate: output -->
```text
NAME                              TYPE                 DATA   AGE
sh.helm.release.v1.bookstore.v1   helm.sh/release.v1   1      4m22s
```

#### Secrets in values and in the release record

The release record holds the rendered manifest and the values you supplied.
Whoever can read Secrets in that namespace can read both. The chart writes the
demo database Secret with `stringData`, so the password is in clear text in
the render. The value is the demo one that the chart ships in `values.yaml`:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | grep "POSTGRES_PASSWORD:"
```

<!-- gate: output -->
```text
  POSTGRES_PASSWORD: "devpassword"
```

Decode the live release record and count that password in it. The count prints,
the password does not:

```sh
kubectl get secret sh.helm.release.v1.bookstore.v1 -n bookstore -o jsonpath="{.data.release}" \
  | base64 -d | base64 -d | gunzip | grep -o "devpassword" | wc -l
```

<!-- gate: output -->
```text
       2
```

It is there twice: a dry run of the install, as JSON, puts one copy in the
stored manifest and one in the chart's default values, which the record carries
too. `helm get values` prints only the values you supplied, so with the defaults
it shows no password. `--all` prints every computed value, password included.
Count the password in each:

```sh
helm get values bookstore -n bookstore --all | grep -c "POSTGRES_PASSWORD"
helm get values bookstore -n bookstore | grep -c "POSTGRES_PASSWORD"
```

<!-- gate: output -->
```text
1
```

<!-- gate: output -->
```text
0
```

Prod turns the demo Secret off:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  -f examples/bookstore/helm/bookstore/values-prod.yaml | grep -c "^kind: Secret"
```

<!-- gate: output -->
```text
0
```

`db-credentials` is gone in prod (`dbCredentials.create: false`). The KEDA
scaler's connection Secret is not rendered in any values file: the chart holds
no AMQP URL for the scaler and no default to fall back to. The one
`rabbitmq-conn` in the prod render is the TriggerAuthentication naming a Secret
that the operator creates, and the chart refuses to render KEDA without that
name (section 6):

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  -f examples/bookstore/helm/bookstore/values-prod.yaml | grep -c "name: rabbitmq-conn"
```

<!-- gate: output -->
```text
1
```

The payments-worker's `AMQP_URL` used to be a plain `guest:guest` string in
every render, prod included: the stock login of this guide's in-cluster
RabbitMQ. It is gone. The broker has no `guest` user now. Its login, and the
`AMQP_URL` that orders and payments-worker read, sit in the same
`db-credentials` Secret as the database login, and the workloads name that
Secret with `secretKeyRef`. Prod does not render the Secret, so the prod render
holds no broker URL at all. Count the stock login and any AMQP URL in it. The
captures in this part come from a second run of these render checks, made after
the change:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  -f examples/bookstore/helm/bookstore/values-prod.yaml | grep -c "guest:guest"
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  -f examples/bookstore/helm/bookstore/values-prod.yaml | grep -c "amqp://"
```

<!-- gate: output -->
```text
0
```

<!-- gate: output -->
```text
0
```

A zero count means something only if the check can find the string. The default
render is the control: it carries the demo Secret, and the URL is in it.

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | grep -c "amqp://"
```

<!-- gate: output -->
```text
1
```

That one URL, with the demo broker password in it, is the same in-the-clear
demo value as the database password above, and it is why prod turns the demo
Secret off. The Secret that prod needs from the operator now has six keys. The
chart's README lists them.

### 4. Override values, upgrade, roll back

The chart ships per-environment value files. Preview the `dev` override against
the live release using only built-in tooling. `helm get manifest` returns
objects in Helm's apply order and `helm template` writes them in file order, so
a line diff shows large blocks as moved when nothing changed. Compare the kinds
instead. The lab's own values file went last so that it won over
`values-dev.yaml`:

```sh
S=$(mktemp -d)
helm get manifest bookstore -n bookstore > "$S/cur.yaml"
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.create=false -f examples/bookstore/helm/bookstore/values-dev.yaml > "$S/new.yaml"
diff <(grep '^kind:' "$S/cur.yaml" | sort | uniq -c) <(grep '^kind:' "$S/new.yaml" | sort | uniq -c)
rm -rf "$S"
```

<!-- gate: output -->
```text
4d3
<    1 kind: HorizontalPodAutoscaler
5a5
>    1 kind: Job
8d7
<    3 kind: PodDisruptionBudget
```

Dev drops the HPA and the three PodDisruptionBudgets. The `Job` line is only the
hook: `helm template` prints it and the live release manifest does not.

> For a semantic diff of everything else, use the **`helm-diff`** plugin
> (`helm plugin install https://github.com/databus23/helm-diff --version v3.15.15`).
> The plugin runs with your kubeconfig rights, so pin it like a chart:
>
> ```sh
> helm diff upgrade bookstore examples/bookstore/helm/bookstore -n bookstore --set namespace.create=false -f …/values-dev.yaml
> ```
>
> It compares the *live release* to the *proposed* release and reports only
> real changes. This guide did not run the plugin.

Apply it as **revision 2**, then change one value via `--set` as **revision
3** (precedence: `--set` beats `-f` beats chart defaults):

```sh
helm upgrade bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.create=false -f examples/bookstore/helm/bookstore/values-dev.yaml --wait
helm upgrade bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.create=false -f examples/bookstore/helm/bookstore/values-dev.yaml \
  --set catalog.image.tag=dev --set catalogConfig.data.LOG_LEVEL=warn --wait
```

The second upgrade printed:

<!-- gate: output -->
```text
Release "bookstore" has been upgraded. Happy Helming!
NAME: bookstore
LAST DEPLOYED: Sat Oct 31 10:57:18 2026
NAMESPACE: p07-finish-helm
STATUS: deployed
REVISION: 3
```

```sh
helm history bookstore -n bookstore
kubectl get deploy catalog -n bookstore
```

<!-- gate: output -->
```text
REVISION    UPDATED                     STATUS      CHART           APP VERSION DESCRIPTION     
1           Sat Oct 31 10:51:47 2026    superseded  bookstore-0.1.1 dev         Install complete
2           Sat Oct 31 10:56:27 2026    superseded  bookstore-0.1.1 dev         Upgrade complete
3           Sat Oct 31 10:57:18 2026    deployed    bookstore-0.1.1 dev         Upgrade complete
```

<!-- gate: output -->
```text
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
catalog   1/1     1            1           5m51s
```

Three revisions, and the dev override took: catalog runs one replica. The
migration Job re-runs on **every** upgrade, because it is a
`post-install,post-upgrade` hook, and it is idempotent (`CREATE TABLE IF NOT
EXISTS`). Each run leaves a pair of events, and the Job itself is deleted again
when it succeeds. Here are the install and the two upgrades:

```sh
kubectl get events -n bookstore --field-selector involvedObject.name=db-migrate | cut -c1-90
```

<!-- gate: output -->
```text
LAST SEEN   TYPE     REASON             OBJECT           MESSAGE
105s        Normal   SuccessfulCreate   job/db-migrate   Created pod: db-migrate-l9rtd
92s         Normal   Completed          job/db-migrate   Job completed
36s         Normal   SuccessfulCreate   job/db-migrate   Created pod: db-migrate-pxb5h
23s         Normal   Completed          job/db-migrate   Job completed
11s         Normal   SuccessfulCreate   job/db-migrate   Created pod: db-migrate-6cfpg
1s          Normal   Completed          job/db-migrate   Job completed
```

An earlier attempt of this same upgrade, on a heavily loaded lab host, failed:
the hook Job passed its 120 second `activeDeadlineSeconds`, and Helm recorded
the revision as `failed`. Running the command again succeeded. The transcript
header records it. That is the case `--atomic` covers: it rolls a failed
upgrade back for you ([Helm docs](https://helm.sh/docs/helm/helm_upgrade/)).

Roll the **whole app** back to revision 1 (the original full-scale install),
the atomic unit raw `kubectl` could not give us:

```sh
helm rollback bookstore 1 -n bookstore --wait
helm history bookstore -n bookstore
kubectl get deploy catalog -n bookstore
```

<!-- gate: output -->
```text
Rollback was a success! Happy Helming!
```

<!-- gate: output -->
```text
REVISION    UPDATED                     STATUS      CHART           APP VERSION DESCRIPTION     
1           Sat Oct 31 10:51:47 2026    superseded  bookstore-0.1.1 dev         Install complete
2           Sat Oct 31 10:56:27 2026    superseded  bookstore-0.1.1 dev         Upgrade complete
3           Sat Oct 31 10:57:18 2026    superseded  bookstore-0.1.1 dev         Upgrade complete
4           Sat Oct 31 10:57:41 2026    deployed    bookstore-0.1.1 dev         Rollback to 1   
```

<!-- gate: output -->
```text
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
catalog   3/3     3            3           8m52s
```

Revision 4 is the rollback, and catalog is back to three replicas. The rollback
does not rewind history: it re-applies revision 1's stored manifest as a new
revision.

### 5. Prove restricted admission with a server-side dry-run

A client dry-run does not run admission. A **server** dry-run does, including
**Pod Security Admission**. This is the same proof technique Part 05 ch.02 and
Part 06 used; here it certifies the *rendered chart*:

```sh
# Throwaway namespace that ENFORCES restricted (don't reuse the release's ns):
kubectl create namespace bs-verify
kubectl label namespace bs-verify \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted

# Render WITHOUT the chart's own Namespace (we want to test admission into the
# labelled throwaway ns), then server dry-run into it:
S=$(mktemp -d)
helm template bookstore examples/bookstore/helm/bookstore -n bs-verify \
  --set namespace.create=false --set namespace.name=bs-verify \
  | kubectl apply --dry-run=server -n bs-verify -f - > "$S/dry.txt" 2>&1
echo "$(grep -c 'created (server dry run)' "$S/dry.txt") created, $(grep -ci warning "$S/dry.txt") warnings"
rm -rf "$S"
```

<!-- gate: output -->
```text
45 created, 0 warnings
```

No object was refused and no PodSecurity warning was printed. The lab's values
file also skipped the three PriorityClasses that its cluster already had, so it
counted 45. On a cluster without them the same render is 48 objects. Each
Deployment, StatefulSet, Job and CronJob is admitted under `enforce:
restricted` because `_helpers.tpl` renders the per-image restricted
`securityContext` from Part 05 ch.02 (Go services UID 65532 and a read-only
root FS; storefront UID 101; postgres and rabbitmq UID 999 with `fsGroup`, a
read-only root FS and emptyDir mounts for the paths they write outside the
data volume; redis UID 999 with a read-only root FS). Section 1a's schema pins
the fields that these contexts set.

Now a deliberate violation, to see the same namespace refuse a workload. A Pod
that asks for `privileged` is sent to it as a server dry run, so nothing is
created:

```sh
kubectl run bad --image=busybox -n bs-verify --dry-run=server --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"bad","image":"busybox","securityContext":{"privileged":true}}]}}' 2>&1 | head -1
```

<!-- gate: output -->
```text
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity "restricted:latest": privileged (container "bad" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "bad" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "bad" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

```sh
kubectl delete namespace bs-verify         # leave the cluster as you found it
```

### 6. Toggle a CRD-backed extra — and be honest about operators

The observability/scaling extras are CRD-backed, so they default **off**.
KEDA also needs a credential. The scaler reads the queue length over AMQP, so it
needs the broker URL. The chart renders no Secret for it and carries no default.
You create the Secret in the release namespace, with the key `host`, and name it
in `keda.connectionSecretName`. Turn KEDA on without a name first. This step is
a deliberate failure:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set keda.enabled=true 2>&1 | head -n 1
```

<!-- gate: output -->
```text
Error: execution error at (bookstore/templates/83-keda-scaledobject.yaml:19:19): keda.enabled=true needs keda.connectionSecretName: the name of an existing Secret, created by the operator, whose key `host` holds the RabbitMQ AMQP URL. The chart renders no connection Secret and carries no default credential.
```

The render stops at `required` in `templates/83-keda-scaledobject.yaml`, and the
message names the value and says what to create. `values-prod.yaml` enables KEDA
and names `rabbitmq-conn`, so a production render that lost that name would stop
the same way, not fall back to a stock login.

Create the Secret. The value below is a throwaway that `openssl` generates and
nothing prints. It is enough for a render and a dry run. A scaler that connects
needs a broker login that can read the queue. The broker has no `guest` user,
and the login that orders and payments-worker share is not one to hand to a
scaler.
[06.04](../06-production-readiness/04-autoscaling.md) creates a `keda-scaler`
user with read on the `orders` queue and nothing else. Pipe the value in, so it
never sits on a command line:

```sh
AMQP_URL="amqp://demo:$(openssl rand -hex 12)@rabbitmq:5672/"
printf "%s" "$AMQP_URL" | kubectl create secret generic rabbitmq-conn \
  -n bookstore --from-file=host=/dev/stdin
kubectl get secret rabbitmq-conn -n bookstore
```

<!-- gate: output -->
```text
secret/rabbitmq-conn created
# ...
NAME            TYPE     DATA   AGE
rabbitmq-conn   Opaque   1      0s
```

Name it, turn the ServiceMonitor on too, and render:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set serviceMonitor.enabled=true --set keda.enabled=true \
  --set keda.connectionSecretName=rabbitmq-conn \
  | kubectl apply --dry-run=client -f - 2>&1 | grep -E 'ScaledObject|TriggerAuth|ServiceMonitor' | tail
```

If KEDA and the Prometheus Operator are **not** installed you see this, and the
lab cluster has neither:

<!-- gate: output -->
```text
resource mapping not found for name: "payments-worker" namespace: "p07-finish-helm" from "STDIN": no matches for kind "ScaledObject" in version "keda.sh/v1alpha1"
resource mapping not found for name: "catalog" namespace: "p07-finish-helm" from "STDIN": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
resource mapping not found for name: "payments-worker" namespace: "p07-finish-helm" from "STDIN": no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
resource mapping not found for name: "rabbitmq-trigger-auth" namespace: "p07-finish-helm" from "STDIN": no matches for kind "TriggerAuthentication" in version "keda.sh/v1alpha1"
```

That is **expected and correct**, identical to the intrinsic behaviour the raw
manifests
([`83-keda-scaledobject.yaml`](../examples/bookstore/raw-manifests/83-keda-scaledobject.yaml),
`80-`, `51-`, `70-`, `18-`) already documented: the *templated object is
schema-correct*, but the **CRD must exist first**.

The object count stays honest about the Secret. The default render is 49 and
did not move. KEDA on adds the TriggerAuthentication and the ScaledObject, so
51. The chart used to add a third object here, the Secret, and no longer does.
The prod render is 53: the 49, less the database Secret that prod turns off,
plus the two ServiceMonitors, the PrometheusRule and the two KEDA objects:

```sh
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | grep -c "^kind:"
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set keda.enabled=true --set keda.connectionSecretName=rabbitmq-conn | grep -c "^kind:"
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  -f examples/bookstore/helm/bookstore/values-prod.yaml | grep -c "^kind:"
```

<!-- gate: output -->
```text
49
# ...
51
# ...
53
```

The three Kustomize overlays are unaffected: none of them lists the `keda`
component. Install the operator with **Helm** (never a
`releases/latest/download/<PINNED-FILE>.yaml` URL, which 404s when a new
release ships), then the same toggle applies cleanly. This guide installs the
KEDA chart from its HTTP repository, so it pins the tarball by the SHA-256 in
the repository index. Create and label the namespace first, as section 2 does
for `bookstore`, so the install does not leave it unlabelled. The `restricted`
label is what the render check in [ch.05](05-progressive-delivery.md) uses for
the other third-party charts, and the three KEDA Deployments set the
restricted fields in their render. The lab did not run these steps, because
they install an operator and its CRDs on a shared cluster. They are cited from
the KEDA chart's repository index, not captured:

```sh
kubectl create namespace keda
kubectl label namespace keda pod-security.kubernetes.io/enforce=restricted
curl -fsSLO https://kedacore.github.io/charts/keda-2.21.0.tgz
echo "a7da56bf41a33dad9d2fc82a6fdecee552fff947d80bf1e1dbcf4db0f9e26dee  keda-2.21.0.tgz" | shasum -a 256 -c -
helm install keda ./keda-2.21.0.tgz -n keda --wait
helm upgrade bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.create=false --set keda.enabled=true \
  --set keda.connectionSecretName=rabbitmq-conn --wait
kubectl get scaledobject,hpa -n bookstore     # KEDA created the managed HPA
```

The same pattern holds for `serviceMonitor.enabled`/`prometheusRule.enabled`
(needs `kube-prometheus-stack` — and the `release` label must match its
selector, defaulted correctly), `gateway.enabled` (Gateway API CRDs + a
controller; mutually exclusive with `ingress.enabled` — the chart **fails the
render** if both are set), `kyverno.enabled` (Kyverno; the policy is
deliberately **Audit**, never Enforce — Enforce would reject the guide's own
`:dev` images), and `snapshot.enabled` (the external-snapshotter CRDs + a
snapshot-capable CSI driver). The chart README tabulates every toggle and its
prerequisite.

Clean up:

```sh
helm uninstall bookstore -n bookstore
# PriorityClasses + the (opt-in) StorageClass survive — annotated
# helm.sh/resource-policy: keep — so a parallel release/workload still
# referencing them is not broken.
#
# The namespace stays, because you created it. So does the postgres PVC
# `data-postgres-0`: a StatefulSet's volume claims are not release objects, so
# Helm does not delete them. Delete the namespace yourself when the data is
# no longer needed.
kind delete cluster --name bookstore
```

## How it works under the hood

**The render pipeline.** `helm install/upgrade/template` (1) loads the chart
and coalesces values (chart `values.yaml` is the base; each `-f` file is
deep-merged over it left-to-right; each `--set` is applied last — so
**`--set` > `-f` > chart defaults**); (2) validates the merged values against
`values.schema.json` if present (the install **aborts** on a schema violation
— a real guardrail, e.g. our schema rejects a bogus `image.pullPolicy`); (3)
executes every file in `templates/` as a Go `text/template` with the Sprig
function library and Helm's built-in objects (`.Values`, `.Release`,
`.Chart`, `.Capabilities`, `.Files`, `.Template`); (4) strips empties, sorts
objects into a **known apply order** (namespaces and CRDs first, then RBAC,
then the rest — so a single stream applies without "namespace not found"
races), and (5) for `install`/`upgrade` sends them to the API server, where
**normal admission still runs** — schema validation, and crucially **Pod
Security Admission**, which is why a restricted-noncompliant chart would be
rejected here exactly as a raw manifest would.

**Templating internals that matter for this chart.** Go templates are pure
string substitution, so structure is enforced by convention:

- **`include` vs `template`.** `template` is a statement (cannot be piped);
  `include "name" .` is a *function* whose output can be piped — the standard
  is `{{ include "bookstore.labels" (dict ...) | nindent 4 }}`. `nindent`
  newline-prefixes then indents, so a helper can emit a block at any depth.
  This chart's `_helpers.tpl` uses `include` everywhere for exactly this.
- **The "single source of truth" helpers.** `bookstore.dbDsn` renders the
  libpq DSN string **once**; both `catalog` and `orders` pull it via
  `bookstore.dbEnv`, so the rendered `DB_DSN` is **byte-identical** across the
  two (verified: same md5, and equal to the raw-manifests string). Likewise
  `bookstore.podSecurityContext`/`containerSecurityContext` `toYaml` the exact
  per-image restricted block from `values.securityProfiles`, so the chart's
  restricted posture *cannot* drift from Part 05 ch.02 — change it once,
  every workload changes. This is the mechanism that makes "the chart equals
  the app" true rather than aspirational.
- **`required` / `default` / `tpl`.** `required "msg" .Values.x` aborts the
  render if a value is missing (use it for values with no safe default, such
  as the name of the KEDA connection Secret);
  `default "v" .Values.x` supplies a fallback; `tpl "{{ .Values.y }}" .`
  renders a *string value* as a template (for user-supplied templated
  strings). `toYaml` serialises a value sub-tree (used for `resources`,
  `nodeSelector`, etc. so arbitrary overrides pass through).
- **`fail` for invariants.** `bookstore.validateEdge` calls `fail` if
  `ingress.enabled` **and** `gateway.enabled` are both true (they would bind
  the same host/paths via two data planes — the raw-manifests 50-/51- XOR), or
  if `catalog`+`canary` are both on (both define `app: catalog` Pods + a
  `catalog` Service). The render stops with a clear message *before* anything
  is applied — a values mistake becomes a fast, local error.

**The release object.** A release is a Secret named
`sh.helm.release.v1.<NAME>.v<REV>`, type `helm.sh/release.v1`, holding a
base64'd, gzip'd JSON blob: the rendered manifest, the user values, the chart
metadata, and status. `helm upgrade` writes a *new* Secret (revision N+1) and
computes a three-way strategic merge patch (old manifest, new manifest, live
state) so it only changes what differs and does not stomp controller-written
fields. `helm rollback N` re-applies revision N's stored manifest and records
it as a new revision (it never rewinds history). `helm uninstall` deletes the
release's objects and Secrets — except resources annotated
`helm.sh/resource-policy: keep` (the PriorityClasses and the opt-in
StorageClass here, because they are cluster-scoped and may be referenced by
another release/workload; deleting a referenced PriorityClass/StorageClass
would break future Pod admission or PVC binding). **The namespace is not a
release object in practice.** The chart renders a `Namespace`
(`namespace.create=true`, the default, so `helm template` shows all 49
objects), but `helm install` cannot use it. Helm stores the release record in
the namespace before it applies anything, so the namespace must already exist,
and then the chart's own object conflicts with it. Installs therefore set
`namespace.create=false` and provide the labelled namespace themselves.
`helm uninstall` then removes only the release's objects; the namespace and its
PVCs stay.

**Hooks and the migration-Job-as-hook pattern.** A normal release object is
created/updated with the release. A **hook** is an object annotated
`helm.sh/hook: <EVENT>` that Helm applies at a lifecycle point, *outside* the
normal apply, waiting for it before continuing. The Bookstore's `db-migrate`
Job is `helm.sh/hook: post-install,post-upgrade` with
`helm.sh/hook-weight: "5"` and
`helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`. Mechanics:

- **What sequences the migration is the *event*, not the weight.** Helm
  applies *all* normal release objects (including the postgres StatefulSet),
  and only then runs `post-install`/`post-upgrade` hooks — that lifecycle
  ordering is automatic for any post-\* hook and is the ordering raw
  `kubectl apply -f .` could not express. **`hook-weight` does NOT order a
  hook against normal resources**; non-hook objects do not participate in
  hook-weight at all. `hook-weight` only orders hooks **relative to other
  hooks of the same event** (ascending). With a single post-\* hook here, the
  value `"5"` is behaviorally irrelevant — it is kept as a sane anchor so
  that, e.g., a future *pre-migration check* hook at weight `"1"` would run
  before this migration at weight `"5"`. (The Job *also* `pg_isready`-waits
  in-container: hooks guarantee hook *ordering*, not target *readiness*, so
  the app-level wait stays.)
- **`before-hook-creation`** deletes the previous run's Job immediately before
  recreating it. A Job's pod template is immutable; without this, the second
  `helm upgrade` would try to *patch* an existing `db-migrate` Job and fail.
  `hook-succeeded` then GCs a successful Job (a failed one is kept for
  debugging — pair with the Job's own `ttlSecondsAfterFinished`).
- Other hook events: `pre-install`, `pre-/post-upgrade`, `pre-/post-delete`,
  `post-rollback`, and `test` (run by `helm test`). `pre-install` suits "the
  DB must be migrated *before* the app starts" when the app cannot tolerate an
  old schema; this app's services degrade gracefully and the migration is
  idempotent, so `post-*` (after Postgres exists, no separate pre-DB needed)
  is the simpler correct choice and is what we use.

**Application vs library charts; dependencies.** `Chart.yaml`
`type: application` installs into a cluster; `type: library` ships only
`_*.tpl` helpers for *other* charts to `include` (no installable objects) —
the right tool if several first-party charts must share the exact restricted
`securityContext` helper. Subcharts are declared under `Chart.yaml`
`dependencies:` (name/version/repository, optional `condition:` to toggle and
`tags:` to group); `helm dependency update` vendors them into `charts/`, and
parent `values.yaml` keys named after a subchart override its values. A
"real" chart for stock Postgres/Redis/RabbitMQ would typically pull the
**Bitnami** subcharts. **This guide deliberately does not.** Bitnami's charts
are excellent but hide the StatefulSet, the per-image UID/`fsGroup`, and the
scheduling layer behind *their* values API — which would defeat the entire
point of Parts 04–05 (you would no longer see *why* postgres runs as UID 999
with `fsGroup`, a read-only root filesystem and emptyDir mounts for the paths it
writes). So the chart ships **in-house
templates** for those three; subchart dependency mechanics are taught here
conceptually. Helm also has a special **`crds/`** directory (plain YAML,
installed once before templates, never upgraded/deleted by Helm). This chart
intentionally uses **value toggles** for CRD-backed *instances* instead,
because the CRDs belong to external operators (Prometheus Operator, KEDA,
Gateway API, Kyverno, external-snapshotter) installed via *their* charts — a
chart should not ship someone else's CRDs, and the toggles make a vanilla
install succeed while keeping each object schema-correct when enabled.

**Chart testing.** `helm lint` (structure, template parse, schema), `helm
template` (render + read), `kubectl apply --dry-run=client/server` (built-in
schema / full admission incl. PSA), and `helm test` (run `helm.sh/hook: test`
objects against a live release). For CI at scale: `ct` (chart-testing:
lint-and-install on a kind cluster), `helm-unittest` (assert rendered values),
and `helm-diff` (preview an upgrade's three-way diff before applying).

## Production notes

> **In production: version the chart with SemVer, separately from the app.**
> `Chart.yaml` `version` is the *packaging* version (bump on any
> template/values change); `appVersion` tracks the *application* image. CI
> should enforce `version` increments (chart-testing's
> `check-version-increment`). Consumers pin a chart version exactly as they
> pin an image tag.

> **In production: publish charts to an OCI registry, signed.** `helm package`
> then `helm push bookstore-0.1.1.tgz oci://<REGISTRY>/charts` (Helm 3 OCI
> support is GA); install with `helm install … oci://…/bookstore --version 0.1.1`.
> Sign with `helm package --sign` (a provenance `.prov` file) and
> verify with `helm verify`/`--verify`, or use Cosign on the OCI artifact
> (Part 05 ch.03's supply-chain story applies to charts, not just images). A
> classic HTTP `index.yaml` repo (GitHub Pages + `chart-releaser`) still
> works; OCI is the modern default.

> **In production: NEVER put real secrets in `values.yaml`.** The
> `db-credentials` Secret this chart renders is **demo-only** — a Secret is
> base64, not encryption (the same warning as Part 03 ch.02 / Part 05 ch.04).
> Set `dbCredentials.create=false` (as `values-prod.yaml` does), name the KEDA
> connection Secret in `keda.connectionSecretName`, and have
> **External Secrets Operator / Sealed Secrets / Vault** provide both Secrets
> out of band. The chart renders neither in prod, and it refuses to render KEDA
> without the name. Enable encryption-at-rest on the apiserver. For
> values files that *do* contain sensitive config, use `helm secrets`
> (SOPS-backed) so the file is encrypted in Git and decrypted only at
> install. Secrets in `values.yaml` also end up in the release record, and
> `helm get values --all` prints them. The hands-on section shows both.

> **In production: GitOps renders the chart; humans rarely run `helm install`.**
> Argo CD / Flux watch a Git repo, render this chart with
> environment value files, and reconcile — so the cluster state always equals
> Git, `helm rollback` becomes a Git revert, and drift is auto-corrected.
> That is [ch.04](04-gitops-argocd.md); the chart here is built to be rendered
> by a controller (no `--set` of secrets, deterministic output — verified: two
> renders are byte-identical, no `randAlphaNum`/`now` in templates, which is
> mandatory or every reconcile shows false drift).

> **In production: prefer `helm upgrade --install --atomic --wait --timeout`.**
> `--install` makes it idempotent (first run installs);
> `--atomic` auto-rolls-back on failure so a bad deploy never leaves a
> half-applied release; `--wait`/`--timeout` gate on readiness. Add
> `--cleanup-on-fail` to remove objects a failed install created. Preview with
> `helm diff upgrade` first.

> **In production: umbrella charts compose a system; libraries share
> invariants.** A parent ("umbrella") chart with this app + its operators as
> dependencies can stand up an environment in one release. A `type: library`
> chart holding the restricted-`securityContext` helper lets multiple
> first-party charts inherit the *exact* same hardened defaults — the scalable
> version of this chart's `_helpers.tpl` discipline.

> **In production: beware "template soup".** Every conditional is debugging
> surface and a place a value can make the app insecure by default. Keep the
> security/scheduling invariants in helpers (not per-call `--set`), give every
> value a safe default, validate with `values.schema.json`, and when a chart
> becomes mostly conditionals reach for **Kustomize overlays**
> ([ch.02](02-packaging-kustomize.md)) — patch-the-base, no templating
> language — which is often the better fit for "same app, few env deltas".

## Quick Reference

```sh
# Lint / render / dry-run (no cluster needed for the first two)
helm lint   examples/bookstore/helm/bookstore
helm template bookstore examples/bookstore/helm/bookstore -n bookstore | less
helm template bookstore examples/bookstore/helm/bookstore -n bookstore \
  | kubectl apply --dry-run=server -f -            # full admission incl. PSA

# Install / inspect / upgrade / roll back
kubectl create namespace bookstore     # then label it, as in section 2
helm install  bookstore examples/bookstore/helm/bookstore -n bookstore --set namespace.create=false
helm list -n bookstore ; helm status bookstore -n bookstore
helm get manifest bookstore -n bookstore ; helm history bookstore -n bookstore
helm upgrade  bookstore examples/bookstore/helm/bookstore -n bookstore \
  --set namespace.create=false -f examples/bookstore/helm/bookstore/values-prod.yaml \
  --atomic --wait
helm rollback bookstore 1 -n bookstore --wait
helm uninstall bookstore -n bookstore

# Package / publish (OCI)
helm package examples/bookstore/helm/bookstore --version 0.1.1
helm push bookstore-0.1.1.tgz oci://<REGISTRY>/charts
```

Minimal `values.yaml` skeleton (the shape; full documented set in the chart):

```yaml
namespace: { create: true, name: bookstore, psa: { enforce: restricted } }
catalog:                              # one block per workload
  enabled: true
  replicaCount: 3
  image: { repository: bookstore/catalog, tag: dev, pullPolicy: IfNotPresent }
  resources: { requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 250m, memory: 128Mi} }
securityProfiles:                     # the restricted SC per image (helpers use this)
  goService: { pod: {runAsNonRoot: true, runAsUser: 65532, ...}, container: {...} }
dbCredentials: { create: true, secretName: db-credentials, ... }   # DEMO-ONLY
ingress:  { enabled: true,  className: traefik, host: bookstore.localdev.me }
gateway:  { enabled: false }          # XOR ingress (render fails if both on)
hpa: { enabled: true }                # built-in autoscaling/v2 → default ON
keda: { enabled: false, connectionSecretName: "" }   # CRD → OFF; ON needs your Secret's name
serviceMonitor: { enabled: false }    # CRD → default OFF
migrationJob: { enabled: true }       # DB schema as a post-install/upgrade HOOK
priorityClasses: { create: true }     # cluster-scoped, kept on uninstall
```

Checklist:

- [ ] `helm lint` clean; `helm template | kubectl apply --dry-run=server -f -`
      admitted (incl. **PodSecurity**) into a `restricted` namespace
- [ ] CRD-backed objects behind toggles defaulting **off**; vanilla
      `helm install` has **zero** `no matches for kind`
- [ ] Render is **deterministic** (no `now`/`randAlphaNum`) — required for GitOps
- [ ] Repeated YAML (labels, restricted SC, the DSN) lives in `_helpers.tpl`,
      not copy-pasted; mutually-exclusive toggles `fail` the render
- [ ] No secrets in `values.yaml`/release Secret in prod (External Secrets /
      SOPS); `dbCredentials.create=false`; the KEDA connection Secret is named
      in `keda.connectionSecretName`, never rendered by the chart
- [ ] `Chart.yaml` SemVer bumped on chart changes; chart signed & pushed to
      OCI; consumers pin the version
- [ ] `helm upgrade --install --atomic --wait`; rollback path tested
- [ ] `values.schema.json` fixes the baseline fields of every `securityProfiles`
      entry; `--set` of a weaker value fails the render
- [ ] Third-party charts are pinned by digest, checked for a signature,
      rendered and scanned before install; hooks read in the render
- [ ] Secrets stay out of values and out of the release record in prod, and
      `helm get values --all` is treated as secret-bearing output

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **A team migrating from Helm 2 to Helm 3 asks "where does Tiller run in Helm 3?" What's the one-sentence answer, and why was the change so important?**
   <details><summary>Show answer</summary>

   It doesn't — Helm 3 deleted Tiller. The Helm 2 model put a cluster-admin daemon (Tiller) in the cluster so the client could delegate apply rights to it; in Helm 3, `helm` is a *client only*, it talks to the API server with your own credentials, and the release is stored as an in-cluster Secret. This removed a notorious cluster-admin backdoor and made Helm RBAC-correct: you can only `helm install` what your own `kubectl` could.

   </details>

2. **You `helm upgrade` and the rollout fails. You run `helm history bookstore` and see revision 4 is `failed`, revision 3 is `deployed`. What does `helm rollback bookstore 3` actually do at the API level?**
   <details><summary>Show answer</summary>

   It reads the manifest stored in the **revision 3 Secret** (`helm.sh/release.v1` in the release's namespace) and re-applies those objects to the API server — same as if you had run `kubectl apply -f <revision-3-rendered>.yaml`. A new revision (5) is created that records the rollback. The cluster state is restored by *replaying* a stored manifest; nothing magical, just a saved YAML and apply.

   </details>

3. **A chart uses `{{ now }}` in a label. Argo CD reports `OutOfSync` every reconcile. Explain.**
   <details><summary>Show answer</summary>

   `now` is non-deterministic — every `helm template` call produces a different label value, so Argo's "desired vs live" diff always sees a difference and tries to sync. GitOps requires **deterministic rendering**: identical inputs → identical output, every time. Drop `now`, `randAlphaNum`, `uuidv4` from templates; rely on `.Release.Revision` for things you legitimately need to vary across upgrades.

   </details>

4. **Hands-on extension — see the release Secret. Install the Bookstore chart, then `kubectl get secret -n bookstore -l owner=helm`. Look at the type and decode one. What's in there?**
   <details><summary>What you should see</summary>

   One Secret of type `helm.sh/release.v1` per revision (`sh.helm.release.v1.bookstore.v1`, ...). `kubectl get secret sh.helm.release.v1.bookstore.v1 -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip` reveals the full rendered manifest + values + chart files. That single base64+gzip blob is the entirety of Helm's "state" — no Tiller, no server-side controller, just one bookkeeping Secret per revision.

   </details>

5. **A reviewer says "this chart should be Kustomize instead — too many `{{ if }}` blocks." When is that the right call, and when isn't it?**
   <details><summary>Show answer</summary>

   When the deltas across environments are small and concrete (a replica count, an image tag, a host name) and the chart's templating is mostly "render the same YAML conditionally" — Kustomize's patch-the-base model is cleaner, more transparent, and GitOps-native. When the chart is **distributed** (consumed by other teams or sold/published), templating with a documented `values.schema.json` is the more discoverable interface. Many real systems use **both**: a Helm chart for the app, Kustomize post-render for the environment patch. See [ch.02](02-packaging-kustomize.md)'s Helm vs Kustomize closer.

   </details>

6. **A teammate adds `--set securityProfiles.goService.container.allowPrivilegeEscalation=true` to get a sidecar past a startup error. What happens, and what should they do instead?**
   <details><summary>Show answer</summary>

   The render stops before anything is applied: the schema says `value must be false` at that path. The schema covers every `securityProfiles` entry and refuses any field it does not list, so `privileged`, `capabilities.add`, a Pod Security level other than `restricted` and `networkPolicy.enabled=false` are refused too. Values outside those fields, such as the Kyverno action, are not pinned, so a values file can still change them. The right fix is in the workload's image or its command, or a reviewed change to the schema that every profile would also have to satisfy. A flag on the install command is not that review.

   </details>

7. **Prod enables KEDA, and the render fails with "keda.enabled=true needs keda.connectionSecretName". A teammate proposes a default of `amqp://<USER>:<PASSWORD>@...` so the render passes. Why is the failure the better behaviour, and what do you do?**
   <details><summary>Show answer</summary>

A default is a credential the chart ships to every environment that forgets to
override it, and a Secret the chart renders puts the value in Git, in the
render and in the release record, where anyone who can read Secrets in the
namespace can read it. A failed render stops that at review time. Create the
Secret out of band (External Secrets Operator, Sealed Secrets, Vault, or
`kubectl create secret` for a lab), with the AMQP URL under the key `host`,
and name it in `keda.connectionSecretName`. The chart then only references it.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.11 — Building Platform
  Services** (packaging and exposing applications as consumable, versioned
  platform services; where Helm fits in an internal developer platform and
  its operational trade-offs).
- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Configuration Template* (ch.22)**
  (templating a manifest from parameters as a pattern — the conceptual core of
  what Helm automates; the rationale for parameterise-the-variant,
  fix-the-invariant).
- Official: Helm docs — <https://helm.sh/docs/> (charts:
  <https://helm.sh/docs/topics/charts/>; hooks:
  <https://helm.sh/docs/topics/charts_hooks/>; values/best practices:
  <https://helm.sh/docs/chart_best_practices/values/>), and the Kubernetes
  reference on the objects this chart renders:
  <https://kubernetes.io/docs/concepts/workloads/>.
