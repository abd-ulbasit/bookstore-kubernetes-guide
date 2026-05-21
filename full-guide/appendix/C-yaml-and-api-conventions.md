# Appendix C — YAML and API conventions

> A practical reference for the two things every manifest in this guide depends
> on: **YAML** (and its footguns) and the **Kubernetes API conventions**
> (GVK/GVR, `spec`/`status`, labels vs annotations, the immutable-`selector`
> rule, optimistic concurrency, finalizers/ownerReferences, the
> alpha/beta/stable + deprecation policy, Server-Side Apply, and CRDs). Current
> for Kubernetes **v1.30+**. This is reference material — it does **not** follow
> the nine-section chapter anatomy; it cross-links the chapter that *teaches*
> each topic in depth.

---

## Part 1 — YAML essentials and footguns

Kubernetes manifests are YAML. YAML is convenient but has sharp edges; almost
every "the file looks right but the object is wrong" bug is one of these.

### Indentation and structure

- **Spaces only — never tabs.** A literal tab is a YAML syntax error. Configure
  your editor to insert spaces; 2 spaces per level is the Kubernetes norm.
- **Indentation is the structure.** Nesting is by column, not braces. A field
  indented one space too few/many silently belongs to a different parent — the
  document still parses, the object is just wrong.
- **List vs map.** A `- ` prefix is a *sequence item*; `key: value` is a
  *mapping*. `containers:` is a **list** (`- name: app`); `resources:` is a
  **map** (`requests:`/`limits:`). Mixing them ("`containers:` with a map
  underneath") is the most common structural mistake.
- **Trailing whitespace / invisible characters.** Trailing spaces, a BOM, or
  non-breaking spaces from a copy-paste can break parsing or string values in
  ways that are invisible in an editor. `kubectl apply --dry-run=client -f` is
  the fast catch.

### The boolean / type traps

- **The Norway problem.** Unquoted `yes`, `no`, `on`, `off`, `true`, `false`,
  `y`, `n` are parsed as **booleans** by YAML 1.1 (which most tooling follows).
  A country-code value `NO`, a key `on:`, or `version: yes` becomes `false`/`true`.
  **Quote any string that could be read as a boolean** (`"NO"`, `"on"`).
- **Unquoted version strings and numbers.** Under YAML 1.1 (which `kubectl`
  and most Kubernetes tooling follow), `version: 1.10` parses as the *number*
  `1.1` (trailing zero lost); `1.20` → `1.2`. An image tag `1.0` may become
  `1`. A leading-zero value like `id: 0755` may be read as octal. **Quote
  versions and any number-like string that must stay a string**: `tag: "1.0"`,
  `version: "1.20"`. Kubernetes `apiVersion`/image tags/annotations are strings
  — quote them when ambiguous.
- **`null` and `~`.** `null`, `~`, and an *empty value* all mean null. `key:`
  with nothing after it is `null`, not `""` — which differs from an empty map
  `{}` or empty string `""`. For "present but empty" use `{}`, `[]`, or `""`
  explicitly.
- **The empty-map vs null distinction matters in Kubernetes.** `securityContext:`
  (null) is *unset*; `securityContext: {}` is *present and empty* — and for some
  fields the difference changes defaulting/admission behavior. Be explicit.

### Multi-line strings: `|` vs `>` and chomping

```yaml
literal: |          # block scalar: newlines PRESERVED (use for scripts, configs)
  line one
  line two
folded: >           # folded scalar: newlines become spaces (use for prose)
  this is one
  long logical line
keep:   |+           # chomping: keep ALL trailing newlines
strip:  |-           # chomping: strip the final newline (common for one-line values)
clip:   |            # default: clip to a single trailing newline
```

For a single-line secret/token value, `|-` (strip) avoids a stray trailing
newline that breaks the consumer (a classic "the password has a `\n`" bug).

### Anchors, aliases, and why Helm/Kustomize limit them

```yaml
common: &common          # & defines an anchor
  app.kubernetes.io/part-of: bookstore
metadata:
  labels:
    <<: *common            # * references it; << merges the map
```

Anchors/aliases are valid YAML and reduce repetition in *hand-written* files,
but:

- **Kustomize does not honor them as a templating mechanism** — its merging is
  done on parsed objects via transformers/patches, not by YAML aliasing across
  documents. Use `labels:`/patches/`_helpers.tpl`, not anchors, to share config
  across resources ([07-delivery/02](../07-delivery/02-packaging-kustomize.md)).
- **Helm renders Go templates *before* YAML parse**, so anchors inside templates
  interact confusingly with templating; the chart's convention is named
  templates in `_helpers.tpl`, not YAML anchors
  ([07-delivery/01](../07-delivery/01-packaging-helm.md)).
- Anchors don't cross `---` document boundaries, so they can't dedupe across a
  multi-doc manifest anyway.

### Multi-document files

`---` separates independent YAML documents in one file; `...` optionally ends
one. `kubectl apply -f file.yaml` applies *every* document in order — the
guide's raw manifests rely on this. An empty document (just `---`) or a
leading/trailing `---` is harmless. Helm renders one multi-doc stream; Kustomize
emits one ordered multi-doc stream.

### Quick YAML self-check

```sh
kubectl apply --dry-run=client -f manifest.yaml      # parse + local schema validate (no cluster)
kubectl apply --dry-run=server -f manifest.yaml      # + full apiserver admission (incl. PSA)
```

> **Convention used throughout the guide:** quote ambiguous scalars (versions,
> tags, booleans-as-strings, all-digit strings), use `|-` for single-line secret
> values, 2-space indentation, one concern per document, and validate every file
> with `--dry-run` before it enters Git.

---

## Part 2 — Kubernetes API conventions

Every object follows one shape; these conventions are *enforced by the API
server*, not stylistic. The conceptual home for all of this is
[00-foundations/06 — The declarative API model](../00-foundations/06-declarative-api-model.md).

### `apiVersion`, group/version, GVK and GVR

```yaml
apiVersion: apps/v1        # <GROUP>/<VERSION>   (core group = "" → just "v1")
kind: Deployment           # GVK = (apps, v1, Deployment)
```

- **Group** versions an area of the API: `apps/v1`, `networking.k8s.io/v1`,
  `batch/v1`, `rbac.authorization.k8s.io/v1`, `autoscaling/v2`, `policy/v1`. The
  **empty (core) group** is written as just a version: `apiVersion: v1` →
  Pod, Service, ConfigMap, Secret, Namespace, ServiceAccount.
- **GVK (Group/Version/Kind)** = `apiVersion` + `kind`; it identifies the *type*
  and routes the request to the controller and storage that own it.
- **GVR (Group/Version/Resource)** is the lowercase-plural REST form
  (`apps/v1` → `deployments`) used in API paths (`/apis/apps/v1/namespaces/<NS>/deployments`)
  and in **RBAC rules** (`resources: ["deployments"]`, `apiGroups: ["apps"]`).
- Discover the correct, version-current values for *your* cluster — never guess:

```sh
kubectl api-resources                       # KIND, its GROUP, plural NAME, NAMESPACED?
kubectl api-versions                        # every served group/version
kubectl explain deployment.spec --recursive # the authoritative schema for the spec
```

### Namespaced vs cluster-scoped

- **Namespaced** kinds live in a namespace (Pod, Deployment, Service, ConfigMap,
  Secret, Role, RoleBinding, PVC). They are isolated and quota-able per
  namespace.
- **Cluster-scoped** kinds have no namespace (Node, PersistentVolume,
  StorageClass, PriorityClass, ClusterRole, ClusterRoleBinding,
  CustomResourceDefinition, Namespace itself, IngressClass, GatewayClass).
- The Bookstore's three `PriorityClass` objects are cluster-scoped: the
  Kustomize `namespace:` transformer correctly leaves them namespace-free, and
  Helm annotates them `helm.sh/resource-policy: keep` so an uninstall doesn't
  break other workloads ([07-delivery/01](../07-delivery/01-packaging-helm.md),
  [07-delivery/02](../07-delivery/02-packaging-kustomize.md)).
- `kubectl api-resources --namespaced=true|false` tells you which a kind is.

### `metadata`: name, labels vs annotations, the recommended set

```yaml
metadata:
  name: catalog                       # unique within (namespace, kind)
  namespace: bookstore                # namespaced kinds only
  labels:                             # identifying → SELECTED by other objects
    app: catalog
    app.kubernetes.io/name: catalog
  annotations:                        # non-identifying → tools/humans, NOT selectable
    kubernetes.io/change-cause: "bump catalog to 1.4"
  uid: <SERVER-ASSIGNED>              # survives name reuse
  resourceVersion: "<etcd revision>"  # optimistic concurrency (do not set by hand)
  ownerReferences: [ ... ]            # parent → cascading delete / GC
```

- **Labels** are identifying key/values **meant for selection** (Services,
  ReplicaSets, NetworkPolicies, HPAs select on them). Keep them stable and
  intentional. **Rule of thumb: if something selects on it, it's a label;
  otherwise it's an annotation.**
- **Annotations** are arbitrary non-identifying metadata (build SHA,
  change-cause, controller config, checksums). **You cannot select on
  annotations.**
- **The recommended common labels** — adopt this set for consistent selection,
  dashboards, cost allocation, and policy:
  `app.kubernetes.io/name`, `/instance`, `/version`, `/component`,
  `/part-of`, `/managed-by`. The guide standardizes on these
  ([00-foundations/06](../00-foundations/06-declarative-api-model.md)).

### `spec` vs `status`

- You (or a controller) write **`spec`** — *desired* state. The owning
  controller/kubelet writes **`status`** — *observed* state. **You almost never
  write `status`.**
- The divide is real at the API level: many kinds expose a separate `/status`
  **subresource** with its own RBAC, so a controller can update status without
  being able to mutate spec (and vice-versa).
- This is why `kubectl get <OBJ> -o yaml` shows both, and why pasting back a
  dumped object's `status:` is meaningless — drop it.

### The immutable-`selector` rule (a real outage)

`Deployment`/`StatefulSet`/`ReplicaSet` `.spec.selector` and a `Service`'s
`.spec.selector` are **immutable after creation** — the API server rejects any
change:

```
Deployment.apps "catalog" is invalid: spec.selector:
  Invalid value: ...: field is immutable
```

Once that happens the rollout is **wedged** until the workload is deleted and
recreated (downtime). The two ways the guide teaches you to trip this — and
avoid it:

- **Kustomize `commonLabels` footgun.** The legacy `commonLabels:` transformer
  injects its labels into `metadata.labels` **and into `spec.selector` and the
  pod template**. Adding one later mutates the immutable selector. **Fix:** use
  the modern `labels:` transformer with `includeSelectors: false` (and
  `includeTemplates: false`); keep selector labels stable and identical
  base↔overlays; put audit/owner metadata in `commonAnnotations:`
  ([07-delivery/02](../07-delivery/02-packaging-kustomize.md)).
- **Helm "template soup" mutating a selector.** A value toggle that conditionally
  alters selector/pod-template labels causes the same failure. **Fix:** render
  selector labels from a fixed `_helpers.tpl` named template, never from a
  per-environment `--set` ([07-delivery/01](../07-delivery/01-packaging-helm.md)).

> **In production:** make a CI check that `commonLabels:` never appears and that
> `.spec.selector` is byte-identical across base and every overlay/values file.
> This is the cheapest guard against a self-inflicted outage.

### `resourceVersion` and optimistic concurrency

- Every object's `metadata.resourceVersion` reflects etcd's revision at its last
  write. An update must carry the `resourceVersion` it read; the API server
  commits **only if** it is still current (compare-and-swap), else returns
  **`Conflict (409)`** — "the object has been modified; please apply your
  changes to the latest version".
- This is **working as intended**, not a bug: the loser re-reads and
  re-reconciles. Never hard-code or hand-edit `resourceVersion`; let the client
  read-modify-write loop handle it ([00-foundations/06](../00-foundations/06-declarative-api-model.md)).

### finalizers and ownerReferences

- **`metadata.finalizers`** — string keys that **block deletion**: the object
  enters `Terminating` (a `deletionTimestamp` is set) but is not removed from
  etcd until the responsible controller does cleanup and **removes its
  finalizer**. A stuck `Terminating` object is almost always a finalizer whose
  controller is gone — investigate (and only force-remove a finalizer as a last
  resort, knowingly) ([08-day-2-operations/05](../08-day-2-operations/05-operators-and-crds.md)).
- **`metadata.ownerReferences`** — links a child to its parent; deleting the
  parent **garbage-collects** children (ReplicaSet → Pods, Deployment →
  ReplicaSets). `--cascade=foreground|background|orphan` controls ordering.
  Controllers/operators set ownerReferences so cleanup is automatic
  ([08-day-2-operations/05](../08-day-2-operations/05-operators-and-crds.md)).

### Server-Side Apply, `managedFields`, and conflicts

- **Server-Side Apply (SSA)** moves merge logic to the API server. Each field
  records its **manager** in `metadata.managedFields`. The server merges by
  field ownership and reports a **conflict** when two managers set the same
  field with different values.
- This is what makes "Git owns most of a Deployment, an HPA owns
  `spec.replicas`" correct — the conflict surfaces instead of one silently
  clobbering the other.

```sh
kubectl apply -f d.yaml --server-side --field-manager=ci    # claim fields as "ci"
kubectl apply -f d.yaml --server-side --force-conflicts     # take ownership (use deliberately)
kubectl get deploy catalog -o yaml --show-managed-fields     # inspect ownership
```

- Classic **client-side `apply`** instead does a **3-way merge** of (1) your
  manifest, (2) the live object, and (3) the stored *last-applied*
  annotation — enough to tell "user removed a field" from "a controller added
  one". SSA is the modern default for GitOps/CI; resolve conflicts
  intentionally rather than reflexively forcing
  ([00-foundations/06](../00-foundations/06-declarative-api-model.md)).

### alpha / beta / stable and the deprecation/removal policy

- **API maturity:** `v1alpha1` (off by default, may change/disappear, no
  guarantees), `v1beta1` (on by default, may still change, deprecation notice
  before removal), `v1` / stable / **GA** (long-term support).
- **The deprecation policy** (the part that bites in upgrades): a **GA** API
  version is supported for a defined window and **removed only after a
  deprecation period**; beta APIs likewise get notice. Removed examples you must
  not copy from old tutorials: `extensions/v1beta1` Deployment/Ingress,
  `networking.k8s.io/v1beta1` Ingress, `policy/v1beta1` PodSecurityPolicy
  (the whole **PSP API removed in v1.25** — use **PSA**,
  [05-security/02](../05-security/02-pod-security.md)),
  `autoscaling/v2beta2` HPA (use **`autoscaling/v2`**),
  `batch/v1beta1` CronJob (use **`batch/v1`**),
  `policy/v1beta1` PodDisruptionBudget (use **`policy/v1`**).
- **Find and fix removed/changing APIs:**

```sh
kubectl api-resources                                  # what THIS cluster serves now
kubectl api-versions | sort                            # served group/versions
kubectl explain ingress --api-version=networking.k8s.io/v1   # confirm the current GVK
kubectl get --raw '/metrics' | grep apiserver_requested_deprecated_apis  # who still calls deprecated APIs
kubectl convert -f old.yaml --output-version apps/v1   # `kubectl convert` plugin: migrate a manifest
```

> **In production:** **pin and migrate deliberately.** On regulated clusters pin
> the PSA `-version` label (e.g. `v1.30`) so a Kubernetes upgrade can't silently
> change what `restricted` means. Before any control-plane upgrade, scan for
> deprecated API usage (the apiserver metric above, or tools like `pluto`/
> `kubent`) and bump manifests/charts to the current GVK *first*
> ([08-day-2-operations/01](../08-day-2-operations/01-cluster-lifecycle.md)).

### CustomResourceDefinitions: structural schema & validation

- A **CRD** registers a new kind with the API server so custom objects are
  stored/served/RBAC'd like built-ins. A CRD **must** carry a **structural
  OpenAPI v3 schema** (`spec.versions[].schema.openAPIV3Schema`): the apiserver
  uses it to **validate** and to **prune** unknown fields, so a malformed CR is
  rejected at admission just like a built-in.
- CRDs can serve **multiple versions** with a **storage version** and an
  optional **conversion webhook** between them; the same alpha/beta/stable +
  deprecation discipline applies to *your* CRDs too.
- `kubectl explain <YOURCRD>.spec --recursive` works for CRDs because the schema is published to the API server — the same authoritative-reference habit as for built-ins ([08-day-2-operations/05](../08-day-2-operations/05-operators-and-crds.md)).

---

## The universal object skeleton

Every kind you will ever write fits this; everything above is a refinement of
it:

```yaml
apiVersion: <GROUP>/<VERSION>   # GVK — core group is just a version, e.g. v1
kind: <Kind>
metadata:
  name: <NAME>                  # identity within (namespace, kind)
  namespace: <NS>               # namespaced kinds only
  labels: { app: <NAME> }       # identifying → what other objects select on
  annotations: { }              # non-identifying metadata (NOT selectable)
spec: { }                       # DESIRED state — you author this
# status: OBSERVED — written by the owning controller/kubelet, NEVER by you
```

---

## Which chapter teaches this

| Topic | Chapter |
|---|---|
| `spec`/`status`, GVK, labels/selectors, `apply` 3-way merge, **SSA**, `explain` | [00-foundations/06 — The declarative API model](../00-foundations/06-declarative-api-model.md) |
| The admission pipeline that validates these objects | [00-foundations/04 — Control plane deep dive](../00-foundations/04-control-plane-deep-dive.md) |
| The recommended `app.kubernetes.io/*` label set in practice | [00-foundations/06 — The declarative API model](../00-foundations/06-declarative-api-model.md) |
| RBAC rules expressed in GVR (apiGroups/resources) | [05-security/01 — Authn, authz, RBAC](../05-security/01-authn-authz-rbac.md) |
| Deprecation/removal in practice (PSP→PSA, version pinning) | [05-security/02 — Pod security](../05-security/02-pod-security.md) |
| YAML + the immutable-selector footgun in Helm | [07-delivery/01 — Packaging with Helm](../07-delivery/01-packaging-helm.md) |
| YAML + the `commonLabels` immutable-selector footgun in Kustomize | [07-delivery/02 — Packaging with Kustomize](../07-delivery/02-packaging-kustomize.md) |
| Finding/replacing removed APIs across a cluster upgrade | [08-day-2-operations/01 — Cluster lifecycle](../08-day-2-operations/01-cluster-lifecycle.md) |
| Finalizers, ownerReferences, CRDs, structural schema, conversion | [08-day-2-operations/05 — Operators and CRDs](../08-day-2-operations/05-operators-and-crds.md) |

See also: **[Appendix A — kubectl cheatsheet](A-kubectl-cheatsheet.md)** (the
commands), **[Appendix B — Glossary](B-glossary.md)** (every term above
defined), and the official references: API concepts
<https://kubernetes.io/docs/reference/using-api/api-concepts/>, Server-Side
Apply <https://kubernetes.io/docs/reference/using-api/server-side-apply/>, the
deprecation policy <https://kubernetes.io/docs/reference/using-api/deprecation-policy/>,
and CRDs
<https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>.
