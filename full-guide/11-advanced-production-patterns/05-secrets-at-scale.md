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
  SM, …) and its auth (here: Vault's **Kubernetes auth method** — a SA token,
  no static credential).
- **`ExternalSecret` = "pull these keys into this Kubernetes Secret, and keep
  it fresh".** It references a store, lists `remoteRef`s, and ESO **creates
  and continuously reconciles** a normal `Secret`. `refreshInterval` is the
  rotation cadence; `template` lets you reshape values. The workloads consume
  an ordinary `Secret` — **no app change**.
- **Static vs dynamic secrets.** A *static* secret is one value the manager
  stores (rotation = you change it). A **dynamic** secret has *no stored
  password*: the manager (Vault's database engine) **mints a unique,
  short-TTL credential per request** and **destroys it on lease expiry**. A
  leaked dynamic credential is dead in an hour; revocation is instant.
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
too-broad Vault policy; a `refreshInterval` shorter than the Vault dynamic
lease; the synced `Secret` is still a `Secret` — RBAC on it still discloses
cleartext, [Part 03 ch.02](../03-config-and-storage/02-secrets.md)).

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
      sa["ServiceAccount<br/>bookstore-eso<br/>(projected token)"]
      ss["SecretStore vault-backend<br/>(backend + k8s auth)"]
      es["ExternalSecret db-credentials<br/>refreshInterval: 1h"]
      sec[("Secret db-credentials<br/>(SYNCED — same name/keys<br/>as demo 16-)")]
      cat["catalog / orders Pods<br/>secretKeyRef (UNCHANGED)"]
      pg[("postgres StatefulSet<br/>envFrom (UNCHANGED)")]
    end

    es -->|references| ss
    ss -->|"present SA token"| sa
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
(honest: dev, not HA) via pinned Helm and configure k8s auth + policy + the
KV value; (2) install **ESO** (pinned Helm, own namespace); (3) apply the
`SecretStore` + `ExternalSecret` and **swap** the demo Secret for the
Vault-synced one; (4) **dynamic** short-lived DB creds; (5) **revert** and
clean up.

> **The honest setup story (read first).** Vault and ESO genuinely need
> installing — no zero-setup path. Everything is **fully reproducible on a
> single kind cluster**; **Vault is run in DEV mode** (in-memory,
> auto-unsealed, root token `root`) — that is *not* production Vault (no HA,
> no real seal/unseal, no audit device, data lost on restart). The ESO/Vault
> *mechanics* (k8s auth, policy, KV v2, dynamic engine, sync) are real and
> unfaked; only the Vault *deployment topology* is the local substitute.
> Every manifest dry-run runs with **no cluster**.

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
kubectl apply -f examples/bookstore/raw-manifests/10-catalog-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/14-orders-deploy.yaml
kubectl apply -f examples/bookstore/raw-manifests/40-services.yaml
kubectl apply -f examples/bookstore/raw-manifests/21-db-migrate-job.yaml
kubectl wait --for=condition=complete job/db-migrate -n bookstore --timeout=120s
kubectl rollout status deployment/catalog -n bookstore
```

### 1. Vault dev-mode (pinned Helm) + k8s auth + the secret

Install Vault via the **pinned HashiCorp Helm chart** — per this guide's rule,
**never** a `releases/latest/download/<PINNED-FILE>.yaml` URL (same precedent
as Kyverno/KEDA/Argo CD/Istio):

```sh
VAULT_CHART_VERSION=0.28.1          # hashicorp/vault Helm chart (pin)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault -n vault --create-namespace \
  --version "$VAULT_CHART_VERSION" \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root" --wait
#   ^ DEV MODE — in-memory, auto-unsealed, root token "root". NOT production
#     Vault (the file headers + production notes are explicit about this).
kubectl -n vault rollout status statefulset/vault
```

Configure Vault exactly as [`secrets/00-vault-policy-and-role.yaml`](../examples/bookstore/secrets/00-vault-policy-and-role.yaml)
documents (that file is **not** a kubectl object — it is the `vault` CLI it
encodes, the same honesty pattern as the apiserver-level
`cluster/encryption-config.yaml`). Run the commands inside the Vault Pod:

```sh
kubectl -n vault exec -it vault-0 -- sh -c '
  export VAULT_TOKEN=root
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
  printf '\''path "secret/data/bookstore/db" { capabilities = ["read"] }\n''\''path "database/creds/bookstore-app" { capabilities = ["read"] }\n'\'' | vault policy write bookstore-ro -
  vault write auth/kubernetes/role/bookstore-eso \
    bound_service_account_names=bookstore-eso \
    bound_service_account_namespaces=bookstore \
    policies=bookstore-ro ttl=15m
  vault kv put secret/bookstore/db \
    POSTGRES_USER=bookstore POSTGRES_PASSWORD=devpassword POSTGRES_DB=bookstore
'
# The DEMO value `devpassword` now lives in Vault (least-privilege read
# policy, k8s-auth-bound to bookstore:bookstore-eso). In production this is
# the ONLY place it lives — rotated, audited, never in Git.
```

### 2. Install External Secrets Operator (pinned Helm, own namespace)

```sh
ESO_CHART_VERSION=0.10.4            # external-secrets/external-secrets chart (pin)
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --version "$ESO_CHART_VERSION" --set installCRDs=true --wait
kubectl -n external-secrets rollout status deploy/external-secrets
```

Installing ESO created the `external-secrets.io` CRDs (`SecretStore`,
`ClusterSecretStore`, `ExternalSecret`). **This is what makes the manifests
below dry-runnable** — before this, a client dry-run of them prints `no
matches for kind "SecretStore"` (the documented CRD-intrinsic behaviour; each
file header — the exact precedent of `raw-manifests/70-`/`83-`/`51-`/`argocd/`).

### 3. SecretStore + ExternalSecret — the swap from the demo Secret

Apply the ESO identity, the `SecretStore`, then the `ExternalSecret` that is
the **production replacement** for `16-db-credentials.yaml`. The synced
`Secret` is named **exactly `db-credentials` with the same keys**, so
catalog/orders (`secretKeyRef`) and postgres (`envFrom`) consume it
**unchanged** — that byte-identical-keys design is what makes the swap
transparent (the `DB_DSN` the apps build is unchanged):

```sh
kubectl apply -f examples/bookstore/secrets/05-eso-serviceaccount.yaml
kubectl apply -f examples/bookstore/secrets/10-secretstore-vault.yaml
kubectl get secretstore vault-backend -n bookstore \
  -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}'
#   expect Ready=True (ESO authenticated to Vault via k8s auth)

# THE SWAP: delete the demo Secret, let ESO materialise it from Vault.
kubectl delete secret db-credentials -n bookstore --ignore-not-found
kubectl apply -f examples/bookstore/secrets/20-externalsecret-db-credentials.yaml
kubectl get externalsecret db-credentials -n bookstore \
  -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}'
#   SecretSynced=True → ESO created `db-credentials` FROM Vault

kubectl get secret db-credentials -n bookstore \
  -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo        # bookstore
kubectl rollout restart deployment/catalog -n bookstore        # re-read env DSN
kubectl rollout status deployment/catalog -n bookstore
# catalog still serves /books — the source of truth moved to Vault with ZERO
# application change. The synced Secret is an ordinary Opaque Secret; the
# catalog/orders/postgres Pods stay exactly as PSA-restricted-compliant as
# before (ESO injects NOTHING into them — contrast the Vault Agent sidecar).
```

> **The synced object is still a `Secret`.** ESO removes *plaintext-in-Git*
> and centralizes *rotation/audit*; it does **not** change that
> `get secrets`/`pods/exec` still discloses cleartext in-cluster ([Part 03
> ch.02](../03-config-and-storage/02-secrets.md)) or that encryption-at-rest
> still matters ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)).
> ESO is one layer; it stacks on the others, it does not replace them.

### 4. Dynamic, short-lived DB credentials (the strongest form)

[`secrets/30-externalsecret-dynamic-db.yaml`](../examples/bookstore/secrets/30-externalsecret-dynamic-db.yaml)
has Vault's **database secrets engine** *mint* a fresh Postgres role per
request with a 1h TTL — no stored password, lease-revoked on expiry. Configure
the engine (the `vault` CLI in that file's header) then apply it as an
**additive** demo Secret (`bookstore-db-dynamic`, separate from
`db-credentials`):

```sh
kubectl -n vault exec -it vault-0 -- sh -c '
  export VAULT_TOKEN=root
  vault secrets enable database
  vault write database/config/bookstore-pg plugin_name=postgresql-database-plugin \
    allowed_roles=bookstore-app \
    connection_url="postgresql://{{username}}:{{password}}@postgres.bookstore.svc.cluster.local:5432/bookstore?sslmode=disable" \
    username=bookstore password=devpassword
  vault write database/roles/bookstore-app db_name=bookstore-pg \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\''; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl=1h max_ttl=24h
'
kubectl apply -f examples/bookstore/secrets/30-externalsecret-dynamic-db.yaml
kubectl get secret bookstore-db-dynamic -n bookstore \
  -o jsonpath='{.data.username}' | base64 -d; echo
#   → e.g. v-kubernet-bookstore-app-xxxx  (a UNIQUE, Vault-minted Postgres
#     user). A leak is dead after the lease; revocation is instant
#     (`vault lease revoke`). This is the Part 03 ch.02 / Part 05 ch.04
#     "short blast-radius window" production note, made real.
```

> **Honest scope.** The Bookstore builds **one** `DB_DSN` at startup ([Part 03
> ch.02](../03-config-and-storage/02-secrets.md)), so consuming *rotating*
> dynamic creds end-to-end would need a re-render/rollout or a Vault-Agent
> template sidecar — out of scope to wire into the app here. `30-` is
> demonstrated as the **pattern and production direction**; `20-` is the
> drop-in `16-` replacement.

### 5. Revert to the demo baseline (and clean up)

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
  removed — which is why the revert in step 5 cleanly drops `db-credentials`).
  Every `refreshInterval` it re-fetches and re-reconciles — that loop *is* the
  rotation mechanism. The workloads only ever see a `Secret`; ESO is the part
  that knows about Vault.
- **Vault Kubernetes auth = no static credential.** ESO presents the
  `bookstore-eso` SA's **projected token** to Vault's `kubernetes` auth
  method. Vault calls the cluster's TokenReview to verify it, checks the
  token's SA against the role's `bound_service_account_names`/`namespaces`,
  and returns a **short-lived Vault token** scoped to the bound **policy**
  (`bookstore-ro` — read *only* `secret/data/bookstore/db` and the dynamic
  role path; least privilege, the [Part 05 ch.01](../05-security/01-authn-authz-rbac.md)
  rule applied to Vault). There is no long-lived secret to leak; the trust
  anchor is the SA token (rotated by the kubelet) plus the Vault policy. This
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
  note.
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
- **The cloud-Secrets-Manager bridge.** ESO's provider list includes **AWS
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
> audit discipline extended to the secrets manager.

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
# Vault DEV-mode (PINNED Helm — never releases/latest/download URL) — NOT prod
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install vault hashicorp/vault -n vault --create-namespace --version 0.28.1 \
  --set server.dev.enabled=true --set server.dev.devRootToken=root --wait

# External Secrets Operator (PINNED Helm, own namespace)
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --version 0.10.4 --set installCRDs=true --wait

# Configure Vault k8s auth + policy + secret (vault CLI in the Vault Pod)
kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes      # + role/policy/kv (see 00-)

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
      server: "http://vault.vault.svc:8200"
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

3. **ESO is syncing from AWS Secrets Manager but the `ExternalSecret` status shows `SecretSyncError: AccessDenied`. The IRSA SA on the ESO controller has `secretsmanager:GetSecretValue` on the secret. What else might be wrong?**
   <details><summary>Show answer</summary>

   The `SecretStore` `auth.jwt.serviceAccountRef` may not match the ESO controller's SA, so it's using the default SA which lacks the IAM trust policy. Or, the SecretStore points at a different AWS region than where the secret lives. Or, KMS — the secret is encrypted with a customer-managed KMS key and the SA also needs `kms:Decrypt` on that key. Walk the chain: ESO -> SecretStore -> auth method -> IRSA role -> secretsmanager IAM -> KMS IAM. The most common cause is the KMS layer, because the IAM tutorial only mentions secretsmanager.

   </details>

4. **Hands-on: replace the canonical `16-db-credentials.yaml` with an ESO-managed `ExternalSecret` syncing from Vault. Run `kubectl get secret db-credentials -o yaml` before and after. What is byte-identical, and what changed?**
   <details><summary>What you should see</summary>

   Byte-identical: the `data` keys (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `DB_DSN`) and their values, so the consuming Pods don't notice. Changed: `metadata.ownerReferences` now points at the ExternalSecret CR (so deleting the EE cascades the Secret), and `metadata.labels` includes `reconcile.external-secrets.io/managed-by: external-secrets`. The point of the additive swap is that no downstream consumer needs to know — `DB_DSN` is the contract, and the contract is preserved.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.7 — "Secret Management"**: the
  external-secret-manager model, encryption-at-rest, rotation and the
  operational trade-offs of syncing vs mounting vs injecting (the backbone of
  this chapter).
- **Ibryam & Huß, _Kubernetes Patterns_ 2e, ch.25 — _Secure Configuration_**:
  managing sensitive configuration as a pattern and where an external store
  fits relative to the in-cluster `Secret`.
- Official: External Secrets Operator
  <https://external-secrets.io/latest/>, HashiCorp Vault Kubernetes auth
  <https://developer.hashicorp.com/vault/docs/auth/kubernetes> and database
  (dynamic) secrets
  <https://developer.hashicorp.com/vault/docs/secrets/databases>, the Secrets
  Store CSI Driver
  <https://secrets-store-csi-driver.sigs.k8s.io/>, and Sealed Secrets
  <https://github.com/bitnami-labs/sealed-secrets>.
