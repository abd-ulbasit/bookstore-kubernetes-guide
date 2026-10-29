# Bookstore operator — real Kubebuilder operator + admission webhooks

The runnable Go for **Part 11**:

- **ch.01 — Admission webhooks**: `internal/webhook/v1/pod_webhook.go` (a
  mutating + a validating Pod webhook) and `config/webhook/manifests.yaml`
  (`Mutating`/`ValidatingWebhookConfiguration`), `config/certmanager/`.
- **ch.02 — Operator development**: a Kubebuilder (Go layout v4) project — the
  cluster-scoped `BookstoreTenant` CRD (`bookstore.example.com`, `v1alpha1`
  spoke + `v1beta1` hub, conversion webhook), the reconcile loop
  (`internal/controller/`), finalizers, status conditions/observedGeneration,
  envtest tests.
- **ch.03 — API Priority & Fairness**: `config/apf/` — a `FlowSchema` +
  `PriorityLevelConfiguration` bounding this operator's apiserver traffic.

It is **real, runnable, teaching code** (not a production controller): the
reconciled workload is a public `registry.k8s.io/pause:3.9` Deployment — the
point is the controller machinery, not the payload. It deliberately
**contrasts** Part 08 ch.05 ("consuming" CloudNativePG) by *building* an
operator from scratch.

## Layout (Kubebuilder Go/v4)

```
operator/
├── PROJECT                    Kubebuilder project metadata
├── Makefile                   manifests / generate / vet / test / docker-build / deploy
├── Dockerfile                 distroless static nonroot (== app/catalog pattern)
├── go.mod / go.sum            controller-runtime v0.25 + k8s.io v0.37 (K8s v1.37)
├── cmd/main.go                manager: controller + webhooks + leader election
├── api/
│   ├── v1alpha1/              SPOKE: types + conversion (ConvertTo/From) + deepcopy
│   └── v1beta1/               HUB (storage): types + Hub() + deepcopy
├── internal/
│   ├── controller/            reconcile loop + envtest suite
│   └── webhook/v1/            mutating + validating Pod webhooks
├── config/
│   ├── crd/                   the BookstoreTenant CRD (Cluster scope, conversion: Webhook)
│   ├── rbac/                  least-privilege manager Role/Binding/SA
│   ├── manager/               restricted-compliant manager Deployment + ns
│   ├── webhook/               Mutating/ValidatingWebhookConfiguration + Service
│   ├── certmanager/           self-signed Issuer + serving Certificate
│   ├── apf/                   FlowSchema + PriorityLevelConfiguration
│   ├── samples/               sample CR (v1beta1 + v1alpha1, no namespace)
│   └── default/               kustomize overlay tying it together (make deploy)
└── hack/boilerplate.go.txt
```

## BookstoreTenant is cluster-scoped

`BookstoreTenant` is a **cluster-scoped** CRD: `kubectl get bookstoretenant`
takes no `-n`, and the samples carry no `metadata.namespace`. The controller
creates a tenant `Namespace` and a ConfigMap, Service and Deployment inside
it, and Kubernetes only allows a cluster-scoped owner to own both a
cluster-scoped object and namespaced objects in another namespace (see
[Owners and Dependents](https://kubernetes.io/docs/concepts/overview/working-with-objects/owners-dependents/)).
A namespaced `BookstoreTenant` cannot own any of them: controller-runtime
refuses the owner reference, so every reconcile failed with `cross-namespace
owner references are disallowed`.

The Namespace and each child carry a controller `ownerReference` to the
tenant, so deleting a tenant makes the garbage collector delete its namespace
and everything in it. The finalizer therefore has no cluster work left; it is
kept as the hook for external state and only emits an Event.

> **Upgrading an existing install.** The CRD scope changed from `Namespaced`
> to `Cluster`. `spec.scope` is immutable once a CRD is established, so
> applying the new CRD over the old one fails with `spec.scope: Invalid value:
> "Cluster": field is immutable`. Delete the old CRD and recreate it:
> `kubectl delete crd bookstoretenants.bookstore.example.com`, then
> `make install`. Deleting the CRD deletes every `BookstoreTenant`. The old
> controller created each tenant namespace without an owner, so any
> `bookstore-tenant-*` namespaces it left behind are not garbage-collected:
> delete them with `kubectl delete ns`, or re-create the tenant and let the
> new controller adopt the namespace.

## Build & validate (what the chapters run)

```sh
cd examples/bookstore/operator
go vet ./...                       # passes clean
docker build -t bookstore/operator:dev .   # distroless image, ~51 MB
make manifests generate            # regenerate CRD/RBAC/webhook + deepcopy
make test                          # envtest (downloads apiserver+etcd) + unit
```

`make manifests`/`generate`/`test` fetch **pinned** `controller-gen` /
`kustomize` / `setup-envtest` into `./bin` on demand. The committed
`config/**` and `zz_generated.deepcopy.go` are the equivalent of that output,
so `go vet`/`docker build` are green even without those tools installed.

## Dry-run behavior (intrinsic — documented per file)

- **Built-in, dry-run CLEAN**: `config/apf/*`
  (`FlowSchema`/`PriorityLevelConfiguration`), the `CustomResourceDefinition`
  itself, the manager `Namespace`/`Deployment`/`Service`/RBAC, the
  `Mutating`/`ValidatingWebhookConfiguration` objects. The operator's CRD
  (`config/crd/`) was server-side dry-run clean on a Kubernetes v1.37.0 kind
  cluster (kind v0.33.0) on 2026-10-29.
- **CRD/webhook-intrinsic** (the same precedent as the guide's
  `raw-manifests/18-/51-/70-`, `argocd/`, `operators/cnpg-`,
  `cloud/karpenter-`): the **sample CR** prints `no matches for kind
  "BookstoreTenant"` until the CRD is installed; the **webhook** is "not
  present" until the operator Deployment + Service + cert exist; the
  cert-manager `Issuer`/`Certificate` print `no matches` until cert-manager
  is installed. Each file's header states this. Schema-correct throughout.

This tree is **purely additive** — it does not touch any other
`examples/bookstore/**` file or any guide chapter.
