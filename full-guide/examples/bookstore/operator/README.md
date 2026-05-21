# Bookstore operator — real Kubebuilder operator + admission webhooks

The runnable Go for **Part 11**:

- **ch.01 — Admission webhooks**: `internal/webhook/v1/pod_webhook.go` (a
  mutating + a validating Pod webhook) and `config/webhook/manifests.yaml`
  (`Mutating`/`ValidatingWebhookConfiguration`), `config/certmanager/`.
- **ch.02 — Operator development**: a Kubebuilder (Go layout v4) project — the
  `BookstoreTenant` CRD (`bookstore.example.com`, `v1alpha1` spoke +
  `v1beta1` hub, conversion webhook), the reconcile loop
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
├── go.mod / go.sum            controller-runtime v0.19 + k8s.io v0.31 (K8s v1.30+)
├── cmd/main.go                manager: controller + webhooks + leader election
├── api/
│   ├── v1alpha1/              SPOKE: types + conversion (ConvertTo/From) + deepcopy
│   └── v1beta1/               HUB (storage): types + Hub() + deepcopy
├── internal/
│   ├── controller/            reconcile loop + envtest suite
│   └── webhook/v1/            mutating + validating Pod webhooks
├── config/
│   ├── crd/                   the BookstoreTenant CRD (conversion: Webhook)
│   ├── rbac/                  least-privilege manager Role/Binding/SA
│   ├── manager/               restricted-compliant manager Deployment + ns
│   ├── webhook/               Mutating/ValidatingWebhookConfiguration + Service
│   ├── certmanager/           self-signed Issuer + serving Certificate
│   ├── apf/                   FlowSchema + PriorityLevelConfiguration
│   ├── samples/               sample CR (v1beta1 + v1alpha1)
│   └── default/               kustomize overlay tying it together (make deploy)
└── hack/boilerplate.go.txt
```

## Build & validate (what the chapters run)

```sh
cd examples/bookstore/operator
go vet ./...                       # passes clean
docker build -t bookstore/operator:dev .   # distroless image, ~56 MB
make manifests generate            # regenerate CRD/RBAC/webhook + deepcopy
make test                          # envtest (downloads apiserver+etcd) + unit
```

`make manifests`/`generate`/`test` fetch **pinned** `controller-gen` /
`kustomize` / `setup-envtest` into `./bin` on demand. The committed
`config/**` and `zz_generated.deepcopy.go` are the equivalent of that output,
so `go vet`/`docker build` are green even without those tools installed.

## Dry-run behavior (intrinsic — documented per file)

- **Built-in, dry-run CLEAN on any v1.30+ cluster**: `config/apf/*`
  (`FlowSchema`/`PriorityLevelConfiguration`), the `CustomResourceDefinition`
  itself, the manager `Namespace`/`Deployment`/`Service`/RBAC, the
  `Mutating`/`ValidatingWebhookConfiguration` objects.
- **CRD/webhook-intrinsic** (the same precedent as the guide's
  `raw-manifests/18-/51-/70-`, `argocd/`, `operators/cnpg-`,
  `cloud/karpenter-`): the **sample CR** prints `no matches for kind
  "BookstoreTenant"` until the CRD is installed; the **webhook** is "not
  present" until the operator Deployment + Service + cert exist; the
  cert-manager `Issuer`/`Certificate` print `no matches` until cert-manager
  is installed. Each file's header states this. Schema-correct throughout.

This tree is **purely additive** — it does not touch any other
`examples/bookstore/**` file or any guide chapter.
