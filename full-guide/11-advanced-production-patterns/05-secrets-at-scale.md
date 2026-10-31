# 05 — Secrets at scale

> The demo `Secret` does not scale: base64≠encryption ([Part 03 ch.02](../03-config-and-storage/02-secrets.md)),
> plaintext-in-Git is forever ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)),
> manual rotation doesn't happen. The production answer — **External Secrets
> Operator** (`SecretStore`/`ClusterSecretStore`/`ExternalSecret`, refresh,
> templating) syncing from **HashiCorp Vault** (Kubernetes auth method,
> least-privilege policies, KV v2, **dynamic short-lived DB credentials**,
> leases/rotation/revocation), the **Vault Agent injector vs CSI Secrets
> Store vs ESO** trade-off, **SOPS/Sealed-Secrets** and when each, and the
> **cloud-Secrets-Manager bridge** (ESO with AWS/GCP/Azure SM, tying [Part 10
> ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md) workload
> identity) — applied by replacing the demo `16-db-credentials.yaml` with a
> Vault-backed `ExternalSecret`, ADDITIVELY (canonical untouched; swap +
> revert shown).

**Estimated time:** ~60 min read · ~120 min hands-on
**Prerequisites:** [Part 03 ch.02](../03-config-and-storage/02-secrets.md) — demo Secret this chapter replaces with ESO+Vault · [Part 07 ch.04](../07-delivery/04-gitops-argocd.md) — GitOps that makes plaintext-in-Git existential · [Part 10 ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md) — workload identity the cloud-SM bridge consumes
**You'll know after this:** • compare ESO + Vault vs Vault Agent injector vs CSI Secrets Store vs SOPS/Sealed-Secrets · • author a SecretStore + ExternalSecret pulling from Vault with templating · • configure Vault Kubernetes auth + dynamic short-lived DB credentials · • bridge ESO to AWS / GCP / Azure Secrets Manager via cloud workload identity · • design a secrets-rotation strategy that survives leak + audit
**Lab tier:** A (kind). Run it only against a cluster you own. The captured run in [`examples/security-lab/evidence/11-05.txt`](../examples/security-lab/evidence/11-05.txt) used a shared kind cluster with another name, and its namespaces carried a run prefix. The transcript header records each substitution.

<!-- tags: security, platform-engineering, vault, eso, secrets-rotation -->

## Why this exists

[Part 03 ch.02](../03-config-and-storage/02-secrets.md) created
`raw-manifests/16-db-credentials.yaml`, proved `base64 -d` reverses it in one
command, and said in its own header: *"In a real repo you NEVER commit this:
use Sealed Secrets / External Secrets Operator / Vault."*
[Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md) added
encryption-at-rest so etcd is ciphertext. [Part 07 ch.04](../07-delivery/04-gitops-argocd.md)
made it existential: GitOps makes **Git the production control plane**, so a
plaintext Secret in Git is plaintext **forever** (history is immutable). Every
one of those chapters deferred the *operational* answer to here. This chapter
is that answer.

The demo Secret has three problems that only get worse with scale, and this
chapter does **not** re-teach the ones already taught — it builds on them:

1. **It is not really protected at rest by default** (base64; [Part 03
   ch.02](../03-config-and-storage/02-secrets.md)) and even with encryption-at-rest
   ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)) the
   *value* still lives in your cluster's etcd, not a purpose-built audited
   store.
2. **The value lives in Git** (or someone's laptop), so it leaks via the
   single most common path and cannot be cleanly rotated or revoked.
3. **It is static.** A leaked static credential is valid until a human
   notices and rotates it — an unbounded blast-radius window.

The production model inverts all three: the **source of truth is an external
secrets manager** (HashiCorp Vault, or a cloud Secrets Manager), the cluster
holds only a **synced copy** (or a directly-mounted reference), credentials
can be **short-lived and dynamically issued**, and **rotation/revocation are
operations on the manager**, not Git edits. **External Secrets Operator (ESO)**
is the bridge that syncs the manager into a native Kubernetes `Secret` the
unmodified Bookstore already consumes. The reference is *Production Kubernetes*
ch.7 (Secret Management).

## Mental model

**Stop treating the Kubernetes `Secret` as the source of truth. It becomes a
*projection* — synced from, or mounted from, an external manager that owns the
value, its rotation, its audit trail, and (ideally) its short lifetime.**

- **`SecretStore` / `ClusterSecretStore` = "which backend, authenticated
  how".** A namespaced (`SecretStore`) or cluster-scoped
  (`ClusterSecretStore`) ESO object describing a backend (Vault, AWS/GCP/Azure
  SM, …) and its auth (here: Vault's **Kubernetes auth method**: ESO asks the
  cluster for a short-lived token for one ServiceAccount, and no password is
  stored).
- **`ExternalSecret` = "pull these keys into this Kubernetes Secret, and keep
  it fresh".** It references a store, lists `remoteRef`s, and ESO **creates
  and continuously reconciles** a normal `Secret`. `refreshInterval` is the
  rotation cadence; `template` lets you reshape values. The workloads consume
  an ordinary `Secret` — **no app change**.
- **Static vs dynamic secrets.** A *static* secret is one value the manager
  stores (rotation = you change it). A **dynamic** secret has *no stored
  password*: the manager (Vault's database engine) **mints a unique,
  short-TTL credential per request** and **destroys it on lease expiry**. A
  leaked dynamic credential is dead in an hour; revocation is instant. ESO
  reads these through a **generator** (`VaultDynamicSecret`), because its
  Vault provider reads only KV paths. Section 5 of the hands-on shows it.
- **Three ways to get a manager's secret into a Pod** — ESO (sync to a
  `Secret`, app unchanged), the **Vault Agent Sidecar Injector** (an injected
  sidecar templates the secret to a file in the Pod — *injects a container*,
  the [ch.04](04-service-mesh.md)/[ch.01](01-admission-webhooks.md) PSA
  footgun applies), and the **Secrets Store CSI driver** (mount the secret as
  a CSI volume; optionally also sync to a `Secret`). Same goal, different
  trade-offs (Diagram B).
- **Sealed Secrets / SOPS are the *GitOps-native, no-external-manager*
  variants.** **Sealed Secrets**: commit an *encrypted* `SealedSecret`; an
  in-cluster controller decrypts it to a `Secret`. **SOPS** (+ KSOPS/Flux):
  encrypt the values *in the YAML* with a KMS/age key, decrypt at apply. They
  keep cleartext out of Git **without** running Vault — different operational
  model, not strictly worse (when to use which: How it works).

The trap to keep in view: **adopting ESO/Vault does not delete the demo
Secret's lessons — it operationalizes them, and it adds its own footguns**
(an injected Vault-agent sidecar in a PSA-`restricted` namespace; a
too-broad Vault policy; a `refreshInterval` longer than the Vault dynamic
lease, so the credential expires before the next refresh; the synced `Secret` is still a `Secret`, and RBAC on it still discloses
cleartext, [Part 03 ch.02](../03-config-and-storage/02-secrets.md)).

## Threats and controls

| Threat | Control taught here | Goes deeper |
|--------|---------------------|-------------|
| **I6**: a static database password, copied into Git or a Secret, stays valid until someone rotates it | Dynamic credentials: Vault creates a Postgres role per lease and revokes it at expiry (section 5) | [Part 15 ch.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md) |
| **S7**: a Vault role bound to a whole namespace, or to `*`, lets any workload there log in and read the same secret | The Kubernetes auth role names one ServiceAccount and one namespace, and its policy reads two paths (section 4) | [Part 15 ch.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md) (tenants) |
| **I2**: the ESO controller can read every Secret and mint tokens for any ServiceAccount in the cluster | Scoped RBAC: `scopedRBAC` and `scopedNamespace` confine the controller to one namespace (section 2) | [Part 05 ch.01](../05-security/01-authn-authz-rbac.md) |
| **I1**: a synced Secret is still a Secret, readable by anyone with `get secrets` | Encryption at rest and narrow RBAC on the synced Secret. ESO replaces neither | [Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md) |

Scoping does not reach everything. The chart's cert-controller keeps a
cluster-wide read on Secrets, because it manages the webhook certificates.
Section 2 shows that residual, and the Production notes say what to do about it.

## Diagrams

### Diagram A — ESO → SecretStore → Vault (k8s auth) → synced Secret → Pod, with rotation (Mermaid)

```mermaid
flowchart LR
    subgraph vaultns["vault namespace (dev-mode Vault — NOT bookstore)"]
      vault["HashiCorp Vault<br/>KV v2: secret/bookstore/db<br/>DB engine: dynamic creds<br/>policy bookstore-ro (least priv)"]
    end
    subgraph esons["external-secrets namespace"]
      eso["External Secrets Operator<br/>(controller)"]
    end
    subgraph bs["bookstore namespace (PSA restricted)"]
      sa["ServiceAccount<br/>bookstore-eso<br/>(no mounted token)"]
      ss["SecretStore vault-backend<br/>(backend + k8s auth)"]
      es["ExternalSecret db-credentials<br/>refreshInterval: 1h"]
      sec[("Secret db-credentials<br/>(SYNCED — same name/keys<br/>as demo 16-)")]
      cat["catalog / orders Pods<br/>secretKeyRef (UNCHANGED)"]
      pg[("postgres StatefulSet<br/>envFrom (UNCHANGED)")]
    end

    es -->|references| ss
    ss -->|"TokenRequest for the SA"| sa
    eso -->|"reconciles ExternalSecret"| es
    eso -->|"k8s-auth login (SA token → short Vault token)"| vault
    vault -->|"read secret/bookstore/db"| eso
    eso -->|"create+keep in sync"| sec
    sec --> cat
    sec --> pg
    vault -. "rotate value / lease expiry" .-> eso
    eso -. "refreshInterval → re-read → update Secret" .-> sec
    note["No static credential anywhere: trust = SA token + Vault policy.<br/>App consumes a NORMAL Secret. ESO injects NOTHING into app Pods<br/>(contrast the Vault Agent sidecar — that one DOES, PSA footgun)."]
    sa -.-> note
```

### Diagram B — ESO vs Vault-Agent vs CSI, and static vs dynamic (ASCII)

```
 GET A MANAGER'S SECRET INTO A POD — pick the delivery model ────────────────

  EXTERNAL SECRETS OP (ESO)     VAULT AGENT INJECTOR        CSI SECRETS STORE
  ┌────────────────────────┐    ┌────────────────────────┐ ┌────────────────┐
  │ ext mgr → K8s Secret   │    │ injected sidecar writes │ │ CSI vol mounts │
  │ app reads Secret       │    │ secret to a file in Pod │ │ secret as file │
  │  (UNCHANGED)           │    │  (app reads file)       │ │ (opt. → Secret)│
  └────────────────────────┘    └────────────────────────┘ └────────────────┘
  no pod mutation               INJECTS A CONTAINER ►       CSI driver + Pod
  app-agnostic, GitOps-clean    PSA-RESTRICTED FOOTGUN       volume; no Secret
  ◄═ Bookstore uses THIS          (sidecar must be            object needed if
     (consumer Pods untouched)    restricted-compliant or     mount-only
                                  PSA rejects the Pod)
  Many backends (Vault, AWS/     Vault-only, richest          K8s-native mount,
  GCP/Azure SM, …)               templating/leasing           per-Pod identity

  STATIC secret                         DYNAMIC secret (Vault DB engine)
  ───────────────────────────────────   ───────────────────────────────────
  one stored value; rotate = change     NO stored password; minted PER
  it; leak valid until rotated          REQUEST, short TTL, lease-revoked;
  (20-externalsecret-db-credentials)    leak dead in ~1h (30-...-dynamic-db)

  Sealed Secrets / SOPS = NO external manager: cleartext kept out of Git via
  in-cluster decrypt (SealedSecret) / KMS-encrypted YAML (SOPS). Use when you
  want GitOps secrecy without operating Vault.
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter adds the **new** [`examples/bookstore/secrets/`](../examples/bookstore/secrets/)
tree and uses it as the **production replacement** for the demo
`raw-manifests/16-db-credentials.yaml`. It does **not** modify
`16-db-credentials.yaml` or any other canonical file — the swap is
operational and reversible (the `16-` file remains the documented local-lab
baseline; same additive discipline as the operator/mesh precedents).

We will: (0) self-bootstrap the Bookstore; (1) run **Vault dev-mode** on kind
(honest: dev, not HA) via pinned Helm and configure k8s auth, policy and the
KV value; (2) install **ESO** (pinned Helm, own namespace), first with its
defaults and then scoped; (3) apply the `SecretStore` + `ExternalSecret` and
**swap** the demo Secret for the Vault-synced one, then look at a failed sync;
(4) prove the Vault role admits one ServiceAccount and refuses another; (5)
**dynamic** short-lived DB creds; (6) **revert** and clean up.

> **The honest setup story (read first).** Vault and ESO genuinely need
> installing — no zero-setup path. Everything is **fully reproducible on a
> single kind cluster**; **Vault is run in DEV mode** (in-memory,
> auto-unsealed, root token `root`) — that is *not* production Vault (no HA,
> no real seal/unseal, no audit device, data lost on restart). The ESO/Vault
> *mechanics* (k8s auth, policy, KV v2, dynamic engine, sync) are real and
> unfaked; only the Vault *deployment topology* is the local substitute.
> Client dry-runs of the built-in kinds need no cluster. The ESO kinds need
> the ESO CRDs, which section 2 installs first.

### 0. Prerequisites — the running Bookstore (self-bootstrapping)

Identical self-bootstrap to the prior chapters (Vault and ESO install into
their **own** namespaces — `vault` / `external-secrets` — never `bookstore`):

```sh
kind delete cluster --name bookstore 2>/dev/null || true
kind create cluster --name bookstore
cd examples/bookstore/app
for s in catalog orders payments-worker storefront; do docker build -t bookstore/$s:dev ./$s; done
cd ../../..
for s in catalog orders payments-worker storefront; do kind load docker-image bookstore/$s:dev --name bookstore; done

kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
kubectl apply -f examples/bookstore/raw-manifests/15-catalog-config.yaml
kubectl apply -f examples/bookstore/raw-manifests/16-db-credentials.yaml   # the DEMO baseline (we replace this)
kubectl apply -f examples/bookstore/raw-manifests/35-priorityclasses.yaml
kubectl apply -f examples/bookstore/raw-manifests/20-postgres-statefulset.yaml
kubectl rollout status statefulset/postgres -n bookstore
kubectl apply -f examples/bookstore/raw-manifests/12-redis.yaml   # catalog's /readyz needs the cache
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/14-orders-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=120s
kubectl rollout status deployment/catalog -n bookstore
```

### 1. Vault dev-mode (pinned Helm) + k8s auth + the secret

Label the namespace first, so that the Vault Pod is admitted only as
`restricted`:

```sh
kubectl create namespace vault
kubectl label namespace vault \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
```

Install Vault from the **pinned HashiCorp Helm chart**, per this guide's rule
of never installing from a `releases/latest` URL. Chart 0.34.1 runs Vault
2.0.4, and the image is pinned by digest. The chart's own security values make
the server Pod meet `restricted`. The injector stays off: it adds a sidecar
that a `restricted` namespace rejects unless the sidecar is itself compliant
(see How it works under the hood).

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault -n vault --version 0.34.1 --wait \
  --set server.dev.enabled=true \
  --set server.dev.devRootToken=root \
  --set injector.enabled=false \
  --set server.image.tag="2.0.4@sha256:5be49781ecf78bfe775c5309c6a4d9f4e9e040b6c885c99eb2b12fb69855e1a2" \
  --set-json 'server.statefulSet.securityContext.pod={"runAsNonRoot":true,"runAsUser":100,"runAsGroup":1000,"fsGroup":1000,"seccompProfile":{"type":"RuntimeDefault"}}' \
  --set-json 'server.statefulSet.securityContext.container={"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}'
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=240s
```

> **Dev mode is not secure.** Its root token is the chart default, so anyone
> who reaches port 8200 owns Vault. Its data lives in memory, and its traffic
> is plain HTTP. The lab uses it because it starts without unseal keys. Do not
> use these flags for anything that holds real data. Part 15 ch.05 covers the
> production layout.

Configure Vault exactly as [`secrets/00-vault-policy-and-role.yaml`](../examples/bookstore/secrets/00-vault-policy-and-role.yaml)
documents (that file is **not** a kubectl object — it is the `vault` CLI it
encodes, the same honesty pattern as the apiserver-level
`cluster/encryption-config.yaml`). Each command runs in the Vault Pod:

```sh
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault auth enable kubernetes
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root sh -c \
  'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN=root vault policy write bookstore-ro - <<'EOF'
path "secret/data/bookstore/db" { capabilities = ["read"] }
path "database/creds/bookstore-app" { capabilities = ["read"] }
EOF
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault write auth/kubernetes/role/bookstore-eso \
  bound_service_account_names=bookstore-eso \
  bound_service_account_namespaces=bookstore \
  policies=bookstore-ro ttl=15m
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault kv put secret/bookstore/db \
  POSTGRES_USER=bookstore POSTGRES_PASSWORD=devpassword POSTGRES_DB=bookstore
```

The demo value `devpassword` now lives in Vault, behind a read-only policy
and a role bound to `bookstore:bookstore-eso`. In production this is the
only place it lives: rotated, audited, never in Git.

### 2. Install External Secrets Operator (pinned Helm, own namespace)

Before ESO is installed, the API server does not know the `SecretStore` kind,
so a dry-run of its manifest fails. Run it now to see the expected message:

```sh
kubectl apply --dry-run=server -f examples/bookstore/secrets/10-secretstore-vault.yaml
```

The lab's message names the missing kind. It is followed by `ensure CRDs are
installed first`, which is the expected message:

> no matches for kind "SecretStore" in version "external-secrets.io/v1"

Label the namespace, then install ESO at chart 2.12.0 (app v2.12.0). Its three
images, the controller, the webhook and the cert-controller, are pinned by
digest. The chart's repository is added first. The digest is the one the
registry reports for the `v2.12.0` tag, checked before the install:

```sh
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
kubectl create namespace external-secrets
kubectl label namespace external-secrets \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --version 2.12.0 --set installCRDs=true \
  --set image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --set webhook.image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --set certController.image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --wait
```

The chart's default RBAC lets the controller read, write and delete Secrets in
every namespace, and create ServiceAccount tokens in every namespace. Check
that before you scope it. The controller's ServiceAccount is `external-secrets`:

```sh
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets get secrets -n kube-system
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets create serviceaccounts --subresource=token -n kube-system
```

<!-- gate: output -->
```text
yes
```

<!-- gate: output -->
```text
yes
```

Both answer `yes`. Now scope the controller to the `bookstore` namespace. The
scoped install creates its Role in `bookstore`, so section 0 must have created
that namespace first:

```sh
helm upgrade external-secrets external-secrets/external-secrets -n external-secrets \
  --version 2.12.0 --reuse-values --set scopedRBAC=true --set scopedNamespace=bookstore --wait
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets get secrets -n kube-system
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets get secrets -n bookstore
kubectl auth can-i --as=system:serviceaccount:external-secrets:external-secrets-cert-controller get secrets -n kube-system
```

<!-- gate: output -->
```text
no
```

<!-- gate: output -->
```text
yes
```

<!-- gate: output -->
```text
yes
```

The first check now answers `no`, and the second `yes`. The third answers
`yes`, and that is the residual. The cert-controller is a separate
ServiceAccount, and the chart still gives it a cluster-wide read on Secrets,
because it manages the webhook certificates. Treat that ServiceAccount as a
privileged identity: limit who can run as it, and enforce that with policy as
code ([Part 05
ch.07](../05-security/07-admission-control-and-policy-as-code.md)).

Installing ESO created the `external-secrets.io` CRDs (`SecretStore`,
`ClusterSecretStore`, `ExternalSecret`), and the dry-run above now succeeds.
The CRD-intrinsic note still applies: each file header says which kind it
needs, and the same message appears before the CRDs exist.

> **Scoping the chart is not the last RBAC step.** Deleting the namespace
> deletes the scoped Role and RoleBinding the chart created inside it. The lab
> saw that after it rebuilt `bookstore`: ESO could no longer list its
> ExternalSecrets until the release's own manifest was applied again. If you
> rebuild the namespace, reapply the release's Role and RoleBinding for it.

### 3. SecretStore + ExternalSecret — the swap from the demo Secret

Apply the ESO identity, the `SecretStore`, then the `ExternalSecret` that is
the **production replacement** for `16-db-credentials.yaml`. The synced
`Secret` is named **exactly `db-credentials` with the same keys**, so
catalog/orders (`secretKeyRef`) and postgres (`envFrom`) consume it
**unchanged** — that byte-identical-keys design is what makes the swap
transparent. The Deployments build `DB_DSN` from those three keys, so it does
not change:

```sh
kubectl apply -f examples/bookstore/secrets/05-eso-serviceaccount.yaml
kubectl apply -f examples/bookstore/secrets/10-secretstore-vault.yaml
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True secretstore/vault-backend -n bookstore --timeout=120s
kubectl get secretstore vault-backend -n bookstore -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
```

<!-- gate: output -->
```text
secretstore.external-secrets.io/vault-backend condition met
```

<!-- gate: output -->
```text
Valid
```

`Valid` means ESO logged in to Vault with the `bookstore-eso` token and read the
store. Now the swap. The demo Secret from section 0 is replaced by the one ESO
writes. Deleting the Secret alone does not start a new sync, because the
ExternalSecret still reports the last sync as good. So the ExternalSecret is
deleted with it and applied again:

```sh
kubectl delete externalsecret db-credentials -n bookstore --ignore-not-found
kubectl delete secret db-credentials -n bookstore --ignore-not-found
kubectl apply -f examples/bookstore/secrets/20-externalsecret-db-credentials.yaml
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True externalsecret/db-credentials -n bookstore --timeout=150s
kubectl get externalsecret db-credentials -n bookstore -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
kubectl get secret db-credentials -n bookstore -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo
kubectl get secret db-credentials -n bookstore -o jsonpath='{.metadata.labels}{"\n"}'
kubectl get secret db-credentials -n bookstore -o jsonpath='{.metadata.annotations}{"\n"}'
```

<!-- gate: output -->
```text
externalsecret.external-secrets.io/db-credentials condition met
```

<!-- gate: output -->
```text
SecretSynced
```

<!-- gate: output -->
```text
bookstore
```

<!-- gate: output -->
```text
{"reconcile.external-secrets.io/created-by":"5b928743007fbb8eef330357201c567df6607d61bf03b871a50f23c3","reconcile.external-secrets.io/managed":"true"}
```

<!-- gate: output -->
```text
{"reconcile.external-secrets.io/data-hash":"48bf42a63d0564020f75e00c6cc35eac9f30ec11c09c6307d5670ab8"}
```

The synced Secret carries ESO's ownership labels. `reconcile.external-secrets.io/managed`
is `"true"`, `reconcile.external-secrets.io/created-by` names the owner, and the
`reconcile.external-secrets.io/data-hash` annotation records the data ESO last
wrote. Alert on those names or select by them. No `managed-by` label exists.

The catalog Pods read the Secret when they start, so restart them to move them
to the new source, and wait for the rollout:

```sh
kubectl rollout restart deployment/catalog -n bookstore
kubectl rollout status deployment/catalog -n bookstore --timeout=240s
```

<!-- gate: output -->
```text
Waiting for deployment spec update to be observed...
Waiting for deployment "catalog" rollout to finish: 0 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "catalog" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "catalog" rollout to finish: 1 old replicas are pending termination...
deployment "catalog" successfully rolled out
```

catalog rolls out Ready on the synced Secret, and the application did not
change. The synced object is an ordinary Opaque Secret; the catalog, orders and
postgres Pods stay as PSA-restricted-compliant as before. ESO injects nothing
into them (contrast the Vault Agent sidecar).

> **The synced object is still a `Secret`.** ESO removes *plaintext-in-Git*
> and centralizes *rotation/audit*; it does **not** change that
> `get secrets`/`pods/exec` still discloses cleartext in-cluster ([Part 03
> ch.02](../03-config-and-storage/02-secrets.md)) or that encryption-at-rest
> still matters ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)).
> ESO is one layer; it stacks on the others, it does not replace them.

### 3a. What a failed sync looks like

ESO keeps the last good Secret when a sync fails, and it reports the failure on
the ExternalSecret. The next two ExternalSecrets cause failures on purpose. The
first asks for a key that does not exist. The second asks for a path that the
Vault policy does not allow. Each has its own target Secret, so neither touches
`db-credentials`:

```sh
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-missing-key
  namespace: bookstore
spec:
  refreshInterval: "1m"
  secretStoreRef: { name: vault-backend, kind: SecretStore }
  target: { name: db-missing-key, creationPolicy: Owner }
  data:
    - secretKey: POSTGRES_PASSWORD
      remoteRef: { key: bookstore/no-such-path, property: POSTGRES_PASSWORD }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-forbidden-path
  namespace: bookstore
spec:
  refreshInterval: "1m"
  secretStoreRef: { name: vault-backend, kind: SecretStore }
  target: { name: db-forbidden-path, creationPolicy: Owner }
  data:
    - secretKey: POSTGRES_PASSWORD
      remoteRef: { key: other-team/db, property: POSTGRES_PASSWORD }
EOF
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=False externalsecret/db-missing-key externalsecret/db-forbidden-path -n bookstore --timeout=120s
kubectl get externalsecret db-missing-key db-forbidden-path -n bookstore
kubectl get externalsecret db-forbidden-path -n bookstore -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'
```

<!-- gate: output -->
```text
NAME                STORETYPE     STORE           REFRESH INTERVAL   STATUS              READY   LAST SYNC
db-missing-key      SecretStore   vault-backend   1m                 SecretSyncedError   False
db-forbidden-path   SecretStore   vault-backend   1m                 SecretSyncedError   False
```

<!-- gate: output -->
```text
could not get secret data from provider
```

The rotation case matters more, because the workloads already read that
Secret. This step points the working `db-credentials` at the missing path.
The sync fails, and the keys the workloads read stay in place:

```sh
kubectl patch externalsecret db-credentials -n bookstore --type=merge \
  -p '{"spec":{"data":[{"secretKey":"POSTGRES_USER","remoteRef":{"key":"bookstore/no-such-path","property":"POSTGRES_USER"}}]}}'
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=False externalsecret/db-credentials -n bookstore --timeout=120s
kubectl get externalsecret db-credentials -n bookstore -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
kubectl get secret db-credentials -n bookstore -o jsonpath='{.data}' | jq 'keys'
kubectl apply -f examples/bookstore/secrets/20-externalsecret-db-credentials.yaml
kubectl delete externalsecret db-missing-key db-forbidden-path -n bookstore
```

<!-- gate: output -->
```text
SecretSyncedError
```

<!-- gate: output -->
```text
[
  "POSTGRES_DB",
  "POSTGRES_PASSWORD",
  "POSTGRES_USER"
]
```

> **The failure is visible, and the old value stays.** A failed sync reports
> itself in the ExternalSecret's `Ready` condition. The workloads keep the
> value they read, because ESO does not delete the Secret on a failed sync.
> A failed rotation can still leave env-var consumers on an old password, so
> alert on the condition, not on the pods.

### 4. Who can log in: one ServiceAccount, not the namespace

The Vault role names one ServiceAccount and one namespace. Two calls show what
that means. The first logs in as a second ServiceAccount in the same namespace,
and Vault refuses it. This step causes a refusal on purpose. The second logs in
as `bookstore-eso`, and Vault accepts it:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookstore-other
  namespace: bookstore
automountServiceAccountToken: false
EOF
kubectl -n vault exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 vault write auth/kubernetes/login \
  role=bookstore-eso jwt="$(kubectl -n bookstore create token bookstore-other)"
kubectl -n vault exec vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 vault write -format=json \
  auth/kubernetes/login role=bookstore-eso jwt="$(kubectl -n bookstore create token bookstore-eso)" \
  | jq '.auth | {policies, lease_duration}'
kubectl -n bookstore delete serviceaccount bookstore-other
```

<!-- gate: output -->
```text
Error writing data to auth/kubernetes/login: Error making API request.
URL: PUT http://127.0.0.1:8200/v1/auth/kubernetes/login
Code: 403. Errors:
* service account name not authorized
command terminated with exit code 2
```

<!-- gate: output -->
```text
{
  "policies": [
    "bookstore-ro",
    "default"
  ],
  "lease_duration": 900
}
```

A role bound to `*`, or to the namespace alone, would have admitted
`bookstore-other`, and the policy would then have granted it the same two
paths. That is threat S7 in the table above: the binding is the control, so
it names the identity, not the neighbourhood.

### 5. Dynamic, short-lived DB credentials (the strongest form)

Vault's **database secrets engine** *mints* a fresh Postgres role per request,
with a 1h TTL. There is no stored password, and the lease revokes the role when
it ends. The Vault provider cannot read that engine, so ESO uses the generator
in
[`secrets/30-externalsecret-dynamic-db.yaml`](../examples/bookstore/secrets/30-externalsecret-dynamic-db.yaml).
That file has two objects: a `VaultDynamicSecret`, which asks Vault for a
credential on each refresh, and an `ExternalSecret`, which writes the response
into its own Secret (`bookstore-db-dynamic`, separate from `db-credentials`).
Configure the engine first:

```sh
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault secrets enable database
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault write database/config/bookstore-pg \
  plugin_name=postgresql-database-plugin \
  allowed_roles=bookstore-app \
  connection_url="postgresql://{{username}}:{{password}}@postgres.bookstore.svc.cluster.local:5432/bookstore?sslmode=disable" \
  username=bookstore password=devpassword
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault write database/roles/bookstore-app \
  db_name=bookstore-pg \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h max_ttl=24h
```

> **Lab only: two settings here are insecure.** `sslmode=disable` sends the
> `CREATE ROLE` statements, and the passwords in them, in clear over the
> cluster network. The `username`/`password` pair is a static superuser that
> stays valid and in use, and Vault holds it. A production setup uses
> `sslmode=verify-full` against a Postgres certificate, and rotates that root
> credential with `vault write -force database/rotate-root/bookstore-pg`. The
> guide shows the insecure form only because the lab's Postgres has no
> certificate.

Then apply the generator and its ExternalSecret, and read the username. The
password stays in the Secret, and the next commands use it without printing it:

```sh
kubectl apply -f examples/bookstore/secrets/30-externalsecret-dynamic-db.yaml
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True externalsecret/bookstore-db-dynamic -n bookstore --timeout=150s
kubectl get externalsecret bookstore-db-dynamic -n bookstore -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}{"\n"}'
kubectl get secret bookstore-db-dynamic -n bookstore -o jsonpath='{.data.username}' | base64 -d; echo
U=$(kubectl get secret bookstore-db-dynamic -n bookstore -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret bookstore-db-dynamic -n bookstore -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n bookstore postgres-0 -- env U="$U" PGPASSWORD="$P" sh -c 'psql -h "$(hostname -i)" -U "$U" -d bookstore -tAc "select current_user"'
```

<!-- gate: output -->
```text
SecretSynced
```

<!-- gate: output -->
```text
v-kubernet-bookstor-Itgv5E6am1SeW56r1ReQ-1793429845
```

<!-- gate: output -->
```text
v-kubernet-bookstor-Itgv5E6am1SeW56r1ReQ-1793429845
```

The username is a UNIQUE, Vault-minted Postgres user. Vault truncates the role
name in it, so it starts with `v-kubernet-bookstor-`. The login uses the Pod's
own address, `hostname -i`, and not `127.0.0.1`. That matters. The Postgres
image's `pg_hba.conf` trusts loopback connections, so a login through loopback
accepts any password and proves nothing. A Pod address is not loopback, so the
password rule applies. The next commands show a login with a wrong password,
which must fail, and then the rules the login went through:

```sh
kubectl exec -n bookstore postgres-0 -- env U="$U" PGPASSWORD=wrong-password sh -c 'psql -h "$(hostname -i)" -U "$U" -d bookstore -tAc "select current_user"'
kubectl exec -n bookstore postgres-0 -- sh -c 'F=$(psql -U bookstore -d bookstore -tAc "show hba_file"); grep -v "^#" "$F" | grep .'
```

<!-- gate: output -->
```text
psql: error: connection to server at "10.244.0.232", port 5432 failed: FATAL:  password authentication failed for user "v-kubernet-bookstor-Itgv5E6am1SeW56r1ReQ-1793429845"
command terminated with exit code 2
```

<!-- gate: output -->
```text
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            trust
host    replication     all             ::1/128                 trust
host all all all scram-sha-256
```

The last rule matches every non-loopback address, with `scram-sha-256`. The
trust rules cover only the local socket and loopback, which is why the test
must not use them. The wrong password is refused, so the correct pair works
because it matches the lease.

Now revoke the lease and check again. The count of Vault-made roles is read
before, the revocation is sent, and the count is read again:

```sh
kubectl exec -n bookstore postgres-0 -- psql -U bookstore -d bookstore -tAc "select count(*) from pg_roles where rolname like 'v-%'"
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault lease revoke -prefix database/creds/bookstore-app
kubectl exec -n bookstore postgres-0 -- psql -U bookstore -d bookstore -tAc "select count(*) from pg_roles where rolname like 'v-%'"
```

<!-- gate: output -->
```text
2
```

<!-- gate: output -->
```text
All revocation operations queued successfully!
```

<!-- gate: output -->
```text
2
```

The revocation is queued, not instant. The count above still shows the role
right after the request. The lab read it again every seven seconds, and the
role was gone on the first read after that:

<!-- gate: output -->
```text
0
```

The Secret still holds the revoked pair until the next refresh, so the login
with that pair is tried again. It must fail:

```sh
kubectl exec -n bookstore postgres-0 -- env U="$U" PGPASSWORD="$P" sh -c 'psql -h "$(hostname -i)" -U "$U" -d bookstore -tAc "select current_user"'
```

<!-- gate: output -->
```text
psql: error: connection to server at "10.244.0.232", port 5432 failed: FATAL:  password authentication failed for user "v-kubernet-bookstor-Itgv5E6am1SeW56r1ReQ-1793429845"
command terminated with exit code 2
```

The role is dropped, so the same login fails. The Secret keeps the revoked
pair until the next refresh, and that refresh mints a new one. A leak is
therefore dead once the lease is revoked, and the window before the refresh is
the cost of the design. This is the Part 03 ch.02 / Part 05 ch.04 "short
blast-radius window" production note, made real.

> **Honest scope.** The Bookstore builds **one** `DB_DSN` at startup ([Part 03
> ch.02](../03-config-and-storage/02-secrets.md)), so consuming *rotating*
> dynamic creds end-to-end would need a re-render/rollout or a Vault-Agent
> template sidecar — out of scope to wire into the app here. `30-` is
> demonstrated as the **pattern and production direction**; `20-` is the
> drop-in `16-` replacement.

### 6. Revert to the demo baseline (and clean up)

The swap is **reversible** — back to the documented local-lab Secret:

```sh
kubectl delete -f examples/bookstore/secrets/30-externalsecret-dynamic-db.yaml --ignore-not-found
kubectl delete -f examples/bookstore/secrets/20-externalsecret-db-credentials.yaml   # ESO drops db-credentials
kubectl apply  -f examples/bookstore/raw-manifests/16-db-credentials.yaml             # the demo baseline returns
kubectl delete -f examples/bookstore/secrets/10-secretstore-vault.yaml --ignore-not-found
kubectl delete -f examples/bookstore/secrets/05-eso-serviceaccount.yaml --ignore-not-found
helm uninstall external-secrets -n external-secrets
helm uninstall vault -n vault
kind delete cluster --name bookstore
```

## How it works under the hood

- **ESO is a controller; `ExternalSecret` is a desired-state object.** ESO
  watches `ExternalSecret`s, resolves the referenced `SecretStore`,
  authenticates to the backend, fetches each `remoteRef`, applies the optional
  `template`, and **creates/updates a normal `Secret`** (with
  `creationPolicy: Owner` it also deletes it when the `ExternalSecret` is
  removed, which is why the revert in step 6 cleanly drops `db-credentials`).
  Every `refreshInterval` it re-fetches and re-reconciles — that loop *is* the
  rotation mechanism. The workloads only ever see a `Secret`; ESO is the part
  that knows about Vault.
- **Vault Kubernetes auth = no static credential.** ESO asks the API server
  for a short-lived token for the `bookstore-eso` ServiceAccount (TokenRequest,
  which the controller's RBAC allows), and presents that token to Vault's
  `kubernetes` auth method. Vault calls the cluster's TokenReview to verify it, checks the
  token's SA against the role's `bound_service_account_names`/`namespaces`,
  and returns a **short-lived Vault token** scoped to the bound **policy**
  (`bookstore-ro` — read *only* `secret/data/bookstore/db` and the dynamic
  role path; least privilege, the [Part 05 ch.01](../05-security/01-authn-authz-rbac.md)
  rule applied to Vault). There is no long-lived secret to leak; the trust
  anchor is the short-lived token the API server minted, plus the Vault policy. This
  is the same "identity, not a stored credential" idea as the [ch.04](04-service-mesh.md)
  SPIFFE mTLS and [Part 10 ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md)
  cloud workload identity — one pattern, three surfaces.
- **KV v2 vs the database engine (static vs dynamic).** KV v2
  (`secret/data/...`) is a versioned key/value store — a *static* secret you
  put and rotate. The **database** secrets engine stores only a privileged
  connection + a role's SQL `creation_statements`; on each read it **executes
  them to create a brand-new Postgres user**, returns the creds with a
  **lease**, and on lease expiry/revoke runs the revocation SQL to **drop the
  user**. Dynamic secrets shrink the leaked-credential blast radius from
  "until a human rotates" to "the lease TTL", and make revocation a single
  API call — the strongest version of [Part 03 ch.02](../03-config-and-storage/02-secrets.md)/[Part
  05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)'s rotation
  note. ESO reads the engine through the `VaultDynamicSecret` generator, one
  read per refresh, so the username and password come from one lease.
- **ESO vs Vault Agent Injector vs CSI — the trade-off, and the PSA footgun.**
  - **ESO** (this chapter): syncs to a `Secret`; **app unchanged**, GitOps-
    clean, many backends; the cost is a real `Secret` object exists (RBAC on
    it still discloses). **Injects nothing into app Pods** — the
    catalog/orders/postgres Pods stay PSA-`restricted`-compliant untouched.
  - **Vault Agent Sidecar Injector**: a **mutating webhook** injects an
    `vault-agent` sidecar (and init) that logs into Vault and templates the
    secret to a file in the Pod. Powerful (no `Secret` object; live re-render
    on rotation) but it **injects a container** — in a PSA-`restricted`
    namespace that sidecar/init **must** be restricted-compliant or PSA
    **rejects the whole Pod**: the *same* footgun as [ch.04](04-service-mesh.md)'s
    mesh sidecar and [ch.01](01-admission-webhooks.md)'s mutate-before-validate.
    This is *why* the Bookstore uses ESO, not the agent injector, in its
    restricted namespace.
  - **Secrets Store CSI driver**: mounts the secret as a CSI volume (optionally
    also syncing a `Secret`); Kubernetes-native, per-Pod, no injected app
    sidecar, but needs the CSI driver + provider and a volume on every
    consumer.
- **What the controller can reach.** The chart's default ClusterRole lets the
  controller read and write Secrets, and create `serviceaccounts/token`, in
  every namespace. A compromised controller could therefore mint a token for
  any ServiceAccount in the cluster. `scopedRBAC` with `scopedNamespace` moves
  those grants into one namespace's Roles and turns off the cluster-scoped
  reconcilers, so `ClusterSecretStore` and `ClusterExternalSecret` stop being
  processed. The cert-controller keeps its cluster-wide Secret read, the
  residual section 2 showed.
- **A failed sync.** ESO records the failure in the ExternalSecret's `Ready`
  condition and keeps retrying on its interval. It does not delete the target
  Secret, so the last value stays until a sync succeeds. Section 3a shows both
  cases.
- **Sealed Secrets / SOPS — the no-manager GitOps path, and when to use
  which.** **Sealed Secrets**: a controller holds a private key; you encrypt a
  `Secret` into a `SealedSecret` (safe to commit) that **only that cluster's
  controller** can decrypt back into a `Secret`. **SOPS**: encrypts the
  *values inside the YAML* with a KMS/age key; KSOPS/Flux decrypts at apply.
  Use Sealed Secrets/SOPS when you want **cleartext out of Git without
  operating Vault** and don't need dynamic secrets/central rotation/audit;
  use **ESO + Vault/cloud SM** when you need a real secrets manager (dynamic
  creds, central rotation, audit, many consumers, cross-cluster — [ch.06](06-multi-cluster-and-fleet.md)).
  This is the menu [Part 07 ch.04](../07-delivery/04-gitops-argocd.md)'s
  "never plaintext in Git" note pointed at; this chapter is the depth.
- **The cloud-Secrets-Manager bridge.** This chapter does not run it. ESO's
  provider list includes **AWS
  Secrets Manager / GCP Secret Manager / Azure Key Vault**. The
  `SecretStore.spec.provider` changes; the `ExternalSecret` shape is
  identical. Crucially the *auth* uses **cloud workload identity** — IRSA /
  GKE Workload Identity / AKS Workload Identity ([Part 10 ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md))
  — so, exactly like Vault k8s auth, **no static cloud credential** is stored
  in the cluster. ESO is the uniform Kubernetes interface over "whatever
  secrets manager you run".

## Production notes

> **In production: the secrets manager is the source of truth; the
> Kubernetes `Secret` is a disposable projection.** Run ESO (or CSI/Agent)
> against Vault or a cloud Secrets Manager; **never commit the value to Git**
> ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md)). The demo
> `16-db-credentials.yaml` is the documented local-lab exception — treat any
> real plaintext Secret in history as a leaked credential. Keep
> encryption-at-rest on ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md))
> and least-privilege RBAC on the synced `Secret` ([Part 03 ch.02](../03-config-and-storage/02-secrets.md))
> — ESO stacks on those, it does not replace them.

> **In production: run Vault properly — this guide's dev-mode is a teaching
> substitute only.** Production Vault is **HA** (Raft/Consul, ≥3 nodes),
> **auto-unsealed** via a cloud KMS/HSM (never manual unseal keys in a
> runbook), **audit-logged** to a tamper-evident sink, and TLS everywhere. A
> dev-mode Vault loses every secret on restart and has no audit trail —
> acceptable to *learn* the k8s-auth/ESO/dynamic mechanics, unacceptable to
> *operate*.

> **In production: prefer dynamic, short-lived credentials; design rotation
> in.** Vault dynamic DB creds (or cloud equivalents) cap a leak's blast
> radius at the lease TTL and make revocation one API call. Where you must use
> static secrets, set a real `refreshInterval` and remember **env-var
> consumers need a rollout to pick up a rotated value** ([Part 03 ch.02](../03-config-and-storage/02-secrets.md))
> while file/CSI mounts re-sync live — plan the rotation path per consumer,
> and keep `refreshInterval` **shorter than** any Vault dynamic lease.

> **In production: choose the delivery model with the PSA footgun in mind.**
> In a PSA-`restricted` namespace ([Part 05 ch.02](../05-security/02-pod-security.md)),
> the **Vault Agent Sidecar Injector** injects a container that **must** be
> restricted-compliant or PSA rejects every consumer Pod — the same
> mutate-before-validate footgun as [ch.04](04-service-mesh.md)/[ch.01](01-admission-webhooks.md).
> **ESO injects nothing into app Pods** (a `Secret` is synced; consumers
> untouched) and is the safest default for hardened namespaces; if you need
> the Agent or CSI, verify the injected/driver components satisfy `restricted`
> and add an admission/CI check.

> **In production: least-privilege the Vault policy and the auth binding, and
> isolate per tenant.** A Vault policy is RBAC for secrets — scope it to the
> exact paths a workload needs (the `bookstore-ro` policy reads *one* KV path
> + *one* dynamic role, nothing else), bind the k8s auth role to a **dedicated
> SA in a specific namespace**, and give each team/cluster its own policy and
> mount. Audit Vault access; alert on broad reads — the [Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)
> audit discipline extended to the secrets manager. Keep `SecretStore`
> namespaced. A `ClusterSecretStore` lets every namespace it matches read the
> same Vault paths, and the chart's `processClusterStore: false` turns that
> reconciler off where you do not need it.

> **In production (managed — EKS/GKE/AKS):** ESO with the **cloud Secrets
> Manager** + **cloud workload identity** (IRSA / GKE WI / AKS WI, [Part 10
> ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md)) is the
> common pattern — no static cloud credential in the cluster, the manager's
> rotation/audit/IAM for free. The `ExternalSecret` is portable; the
> `SecretStore.provider` + the identity binding are provider-specific. (Cloud
> KMS also backs the [Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)
> encryption-at-rest provider — same KMS, two jobs.)

## Quick Reference

```sh
# Vault: section 1 is the lab's dev-mode substitute. This reference carries no
# Vault install; the production layout is in Part 15 ch.05.

# External Secrets Operator (PINNED chart, digest-pinned images, scoped RBAC).
# The namespace is labelled restricted first (section 2).
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --version 2.12.0 --set installCRDs=true \
  --set scopedRBAC=true --set scopedNamespace=bookstore \
  --set image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --set webhook.image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --set certController.image.tag="v2.12.0@sha256:7a3c4f7e038fa0f86a3172da19b9388f3f4d846e87e9994ee3474c5b72a9330d" \
  --wait

# Vault k8s auth, policy, role and secret: the vault CLI in the Vault Pod (section 1)

# Swap demo Secret → Vault-synced (CRD-backed → dry-run "no matches" until ESO installed)
kubectl apply -f examples/bookstore/secrets/05-eso-serviceaccount.yaml
kubectl apply -f examples/bookstore/secrets/10-secretstore-vault.yaml
kubectl delete secret db-credentials -n bookstore --ignore-not-found
kubectl apply -f examples/bookstore/secrets/20-externalsecret-db-credentials.yaml
kubectl get externalsecret,secretstore -n bookstore
# REVERT: kubectl delete -f .../20-... ; kubectl apply -f raw-manifests/16-db-credentials.yaml
```

Minimal skeletons (full files in `examples/bookstore/secrets/`):

```yaml
# Backend + auth (Vault k8s auth — no static credential)
apiVersion: external-secrets.io/v1
kind: SecretStore                                  # CRD — needs ESO installed
metadata: { name: vault-backend, namespace: <NS> }
spec:
  provider:
    vault:
      server: "https://vault.vault.svc:8200"   # TLS; dev mode is the only http setup
      path: "secret"
      version: "v2"
      auth: { kubernetes: { mountPath: kubernetes, role: <ROLE>,
                            serviceAccountRef: { name: <SA> } } }
---
# Pull keys → keep a normal Secret in sync (the production replacement)
apiVersion: external-secrets.io/v1
kind: ExternalSecret                               # CRD — needs ESO installed
metadata: { name: db-credentials, namespace: <NS> }
spec:
  refreshInterval: "1h"                            # rotation cadence
  secretStoreRef: { name: vault-backend, kind: SecretStore }
  target: { name: db-credentials, creationPolicy: Owner }   # SAME name/keys app expects
  data:
    - { secretKey: POSTGRES_PASSWORD, remoteRef: { key: bookstore/db, property: POSTGRES_PASSWORD } }
```

Checklist:

- [ ] Secrets manager (Vault / cloud SM) is the **source of truth**; the K8s
      `Secret` is a **synced projection** — **never plaintext in Git**
      ([Part 07 ch.04](../07-delivery/04-gitops-argocd.md))
- [ ] ESO via **pinned Helm** in its **own namespace**; Vault in its own
      (prod = HA + auto-unseal + audit; dev-mode is a teaching substitute)
- [ ] **No static credential**: Vault **k8s auth** / cloud workload identity
      ([Part 10 ch.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md));
      Vault **policy least-privilege**, per-tenant
- [ ] Prefer **dynamic short-lived creds**; `refreshInterval` < dynamic lease;
      env-var consumers need a **rollout** to pick up rotation ([Part 03 ch.02](../03-config-and-storage/02-secrets.md))
- [ ] Delivery model chosen with the **PSA footgun** in mind — ESO injects
      nothing; **Vault-Agent/CSI injected components must be `restricted`**
      ([Part 05 ch.02](../05-security/02-pod-security.md), [ch.04](04-service-mesh.md))
- [ ] Canonical `16-db-credentials.yaml` **untouched**; swap is additive +
      **reversible** (byte-identical keys → `DB_DSN` unchanged)
- [ ] Every CRD manifest carries the **CRD-intrinsic** dry-run note; synced
      `Secret` still gets encryption-at-rest + least-priv RBAC ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md))
- [ ] **One identity per role**: the Vault role names one ServiceAccount and
      one namespace, and a second ServiceAccount's login is refused (section 4)
- [ ] **Scoped controller**: `scopedRBAC` and `scopedNamespace` set, no
      `ClusterSecretStore` unless you need one, and `kubectl auth can-i` run
      against the controller (section 2)
- [ ] Dynamic credentials come from a `VaultDynamicSecret` generator, and the
      refresh interval is shorter than the role's TTL (section 5)
- [ ] Every image is pinned by digest, the chart's own image values included

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **What does Vault give you over a Sealed-Secret or SOPS-encrypted manifest in Git?**
   <details><summary>Show answer</summary>

   Dynamic, short-lived credentials (Vault generates a one-time DB user on lease creation and revokes it on expiry), centralized rotation without re-encrypting and re-deploying, audit log of every access, fine-grained Vault policies, and the ability to issue credentials *to* Vault itself from cloud KMS for unsealing. SOPS/Sealed-Secrets are encrypted-static-in-Git: rotation means new commits, key management is your problem, and there is no audit beyond `git log`. Use SOPS/Sealed-Secrets for low-churn config (Helm value files, GitOps repos). Use Vault for credentials that should be short-lived.

   </details>

2. **You're rotating the Postgres password via Vault's dynamic database secrets engine. Apps still hold the old password for ~30s after rotation and fail. What's the design fix?**
   <details><summary>Show answer</summary>

   Either (a) wrap DB access in a connection pool that re-fetches credentials on auth failure and retries (the app handles rotation transparently), (b) sync the credential into a Kubernetes Secret via ESO with a `refreshInterval` shorter than the Vault lease, and use a sidecar (e.g. reloader) to bounce the Pod when the Secret changes — this trades availability for simplicity, (c) for env-var consumers that read the password once at startup, mount the secret as a *file* and have the app re-read on signal/timer. The general pattern: rotation strategy must match how the consumer reads the credential, not the other way around.

   </details>

3. **A teammate sets `bound_service_account_names` to `*` on the Vault role, so that new ServiceAccounts work without a change. What is wrong with that, and how would you show it on the cluster?**
   <details><summary>Show answer</summary>

   Every ServiceAccount in the bound namespace can then log in as the role and
   read the policy's paths, including the database credentials. Show it with a
   second ServiceAccount: mint its token, run the login, and compare. With the
   single name bound, the login is refused (section 4). With `*`, it succeeds.
   The fix is one role per workload identity, each naming its ServiceAccount.

   </details>

4. **Hands-on: replace the canonical `16-db-credentials.yaml` with an ESO-managed `ExternalSecret` syncing from Vault. Run `kubectl get secret db-credentials -o yaml` before and after. What is byte-identical, and what changed?**
   <details><summary>What you should see</summary>

   Byte-identical: the `data` keys (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) and their values, so the consuming Pods don't notice. Changed: `metadata.labels` gains ESO's ownership labels, `reconcile.external-secrets.io/managed: "true"` and `reconcile.external-secrets.io/created-by`, and the `reconcile.external-secrets.io/data-hash` annotation records the data it wrote. With `creationPolicy: Owner`, ESO removes the Secret when the ExternalSecret is deleted. The point of the additive swap is that no downstream consumer needs to know: `DB_DSN` is the contract, and the contract is preserved.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.7 — "Secret Management"**: the
  external-secret-manager model, encryption-at-rest, rotation and the
  operational trade-offs of syncing vs mounting vs injecting (the backbone of
  this chapter).
- **Ibryam & Huß, _Kubernetes Patterns_ 2e, ch.25 — _Secure Configuration_**:
  managing sensitive configuration as a pattern and where an external store
  fits relative to the in-cluster `Secret`.
- External Secrets Operator's Vault provider, which reads KV only, and its
  Vault generator, which makes dynamic secrets:
  <https://external-secrets.io/latest/provider/hashicorp-vault/> and
  <https://external-secrets.io/latest/api/generator/vault/>.
- Official: External Secrets Operator
  <https://external-secrets.io/latest/>, HashiCorp Vault Kubernetes auth
  <https://developer.hashicorp.com/vault/docs/auth/kubernetes> and database
  (dynamic) secrets
  <https://developer.hashicorp.com/vault/docs/secrets/databases>, the Secrets
  Store CSI Driver
  <https://secrets-store-csi-driver.sigs.k8s.io/>, and Sealed Secrets
  <https://github.com/bitnami-labs/sealed-secrets>.
