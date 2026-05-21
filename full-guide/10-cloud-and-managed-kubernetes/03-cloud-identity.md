# 03 — Cloud identity for workloads

> The workload-to-cloud-IAM problem (a Pod needs to call S3/GCS/Blob with
> **no static keys**), solved by **OIDC federation**: the projected,
> audience-bound ServiceAccount token of [Part 05
> ch.01](../05-security/01-authn-authz-rbac.md) exchanged for *scoped,
> short-lived* cloud credentials. The four mechanisms — **EKS IRSA** (cluster
> OIDC provider + IAM role trust + SA annotation + projected token), **EKS Pod
> Identity** (the newer agent/association model), **GKE Workload Identity**
> (KSA↔GSA binding), **AKS Workload Identity** (federated credential) —
> least-privilege scoping *per workload*, token projection + rotation, and the
> pitfalls (trust policy, audience, node-vs-pod identity) — applied by giving
> the Bookstore `catalog`/`orders` ServiceAccounts read access to a cloud
> object-storage bucket with **zero** stored secrets.

**Estimated time:** ~45 min read · ~90 min hands-on
**Prerequisites:** [Part 05 ch.01](../05-security/01-authn-authz-rbac.md) — projected SA tokens this chapter exchanges for cloud creds · [Part 10 ch.01](01-managed-kubernetes-model.md) — managed-cluster OIDC issuer the federation depends on
**You'll know after this:** • explain OIDC federation between a Kubernetes SA and a cloud IAM role · • configure EKS IRSA (trust policy + audience + SA annotation) end to end · • compare IRSA, EKS Pod Identity, GKE Workload Identity, and AKS Workload Identity · • debug the audience/trust-policy mismatch class of identity failures · • scope a workload's cloud permissions to least privilege per SA

<!-- tags: cloud, security, irsa, eks, gke, aks -->

## Why this exists

[Part 05 ch.01](../05-security/01-authn-authz-rbac.md) ended on a sentence this
chapter cashes in: *"the projected, audience-bound SA token is exchanged for a
cloud credential — so the bound-token mechanics are not academic, they are how
Pods get cloud access without static keys."* Now the Bookstore is on a managed
cluster ([ch.01](01-managed-kubernetes-model.md)–[ch.02](02-provisioning-and-iac.md)),
a real cloud need appears: say `catalog` must read book-cover images from an S3/
GCS/Azure bucket, or `orders` must write receipts there. How does that Pod
authenticate to the cloud?

The wrong answers are the reasons this chapter exists:

1. **A static access key in a Secret.** An `AWS_ACCESS_KEY_ID` /
   `GOOGLE_APPLICATION_CREDENTIALS` JSON / Azure client secret baked into a
   Kubernetes Secret. It is base64, not encryption ([Part 03
   ch.02](../03-config-and-storage/02-secrets.md)); it **never expires**; it
   leaks via `helm get values`, a repo commit, a compromised Pod, an over-broad
   `get secrets` ([Part 05 ch.01](../05-security/01-authn-authz-rbac.md)); and
   rotating it across every workload is a project. A long-lived cloud key in a
   cluster is the single highest-value thing an attacker can steal.
2. **The node's identity.** Giving the *node's* instance role the S3
   permission "works" — but now **every Pod on that node** (storefront,
   payments-worker, a compromised sidecar, a noisy neighbour in another
   namespace) inherits it. That is the [Part 05
   ch.01](../05-security/01-authn-authz-rbac.md) `default`-ServiceAccount
   anti-pattern, at cloud-IAM scale: an ambient, shared, over-broad identity
   nobody scoped.

The right answer is **OIDC workload identity federation**: the cluster is an
**OIDC identity provider**, each Pod gets a **projected, audience-scoped,
short-lived SA token** (the *exact* mechanism from [Part 05
ch.01](../05-security/01-authn-authz-rbac.md)), and the cloud is configured to
**trust that issuer** and exchange the token for **temporary, least-privilege
credentials scoped to that one ServiceAccount**. No static key exists anywhere;
the credential auto-rotates; the scope is per-workload. This is the [Access
Control](#further-reading) pattern extended across the cluster/cloud trust
boundary. The reference is *Production Kubernetes* (Identity).

> **This chapter needs a real cloud account.** Federation requires a real
> cloud IAM + a managed cluster's OIDC issuer — it cannot run on kind (kind
> has no IAM to federate with). Per the [ch.01](01-managed-kubernetes-model.md)
> honesty pattern: every provider command/annotation shown is **exact and
> correct**; the **Kubernetes-side artifacts (the annotated ServiceAccount,
> `automountServiceAccountToken`, the pod) are runnable/dry-runnable on kind**
> and are byte-identical to the cloud — only the *cloud trust side* (the IAM
> role/policy, the federated credential) needs the account. No output is
> faked; placeholders only (`123456789012`, `your-org`, `$CLUSTER_NAME`).

## Mental model

**The cluster signs a short-lived "this is ServiceAccount X in namespace Y"
JWT; the cloud is told to trust that signer and hand back temporary
credentials scoped to exactly X/Y. No shared, no static, no node-wide.**

- **The cluster is an OIDC provider.** A managed cluster exposes an **OIDC
  issuer URL** with a public JWKS (set at create time —
  [ch.02](02-provisioning-and-iac.md): `eksctl … withOIDC` /
  `--workload-pool` / `--enable-oidc-issuer`). The kubelet projects a
  **ServiceAccount token** into the Pod that is *signed by the cluster*,
  *time-limited*, *bound to the Pod*, and *audience-scoped* — the bound/
  projected token of [Part 05 ch.01](../05-security/01-authn-authz-rbac.md),
  now with the cloud's STS as the audience.
- **The cloud trusts that issuer for specific subjects.** You register the
  cluster's OIDC issuer as a federated identity provider in the cloud IAM and
  write a **trust/condition** that says: *a token from this issuer whose
  `sub` claim is `system:serviceaccount:bookstore:catalog-sa` (and whose
  `aud` is the cloud STS) may assume **this** IAM role*. The
  `sub`/`aud`/`iss` triple is the entire security boundary — get any of the
  three wrong and it fails closed (the #1 pitfall).
- **The exchange yields temporary, scoped credentials.** The cloud SDK in the
  Pod reads the projected token off disk, calls the cloud STS
  (`AssumeRoleWithWebIdentity` / token exchange), and gets back **short-lived
  credentials for that one role** with **that role's least-privilege policy**
  (e.g. `s3:GetObject` on exactly `arn:aws:s3:::your-org-book-covers/*`). They
  expire and auto-refresh. No key is ever stored.
- **It is per-ServiceAccount, therefore per-workload.** Because the boundary
  is the SA's `sub` claim, **`catalog-sa` and `orders-sa` get different cloud
  roles** with different policies — the [Part 05
  ch.01](../05-security/01-authn-authz-rbac.md) "one identity per workload,
  least privilege" rule, extended to cloud IAM. A compromised `catalog` Pod
  can do *only* what `catalog`'s role allows, and nothing `orders` can.
- **Four flavours, one idea.** **EKS IRSA** (OIDC provider + IAM role
  `AssumeRoleWithWebIdentity` trust + SA annotation
  `eks.amazonaws.com/role-arn` + a webhook that projects the token). **EKS Pod
  Identity** (newer: an on-node *agent* + a `PodIdentityAssociation` mapping
  SA→role — no OIDC-provider/annotation bookkeeping, easier at fleet scale).
  **GKE Workload Identity** (a KSA bound to a Google service account via an
  IAM policy + `iam.gke.io/gcp-service-account` annotation; or the newer
  *direct* KSA-principal grants). **AKS Workload Identity** (the OIDC issuer +
  a Microsoft Entra app/managed-identity **federated credential** + the
  `azure.workload.identity/*` SA annotation/labels). Same federation, four
  configuration surfaces.

The trap to hold onto: **the credential lives in the *token exchange*, not in
the cluster.** There is nothing to rotate, nothing to leak, nothing to put in
a Secret — and if you find yourself creating a Secret with a cloud key on a
managed cluster, you have skipped this entire chapter.

## Diagrams

### Diagram A — Pod → projected SA token → cloud STS → scoped creds (Mermaid)

The runtime exchange. Nothing static is stored; the token is minted per-Pod
and traded for short-lived, role-scoped credentials.

```mermaid
sequenceDiagram
    participant K as kubelet
    participant P as catalog Pod<br/>(SA: catalog-sa)
    participant SDK as Cloud SDK<br/>(in the container)
    participant STS as Cloud STS<br/>(AWS/GCP/Azure token service)
    participant OIDC as Cluster OIDC issuer<br/>(public JWKS)
    participant OBJ as Object store<br/>(S3/GCS/Blob bucket)

    Note over K,P: SA annotated with the cloud role; admission webhook<br/>projects an audience-bound token into the Pod
    K->>P: project SA JWT (aud=cloud STS, sub=system:serviceaccount:bookstore:catalog-sa,<br/>short TTL, auto-rotated) at /var/run/secrets/.../token
    P->>SDK: app calls e.g. s3:GetObject (no keys configured)
    SDK->>SDK: read projected token off disk
    SDK->>STS: AssumeRoleWithWebIdentity / token-exchange (presents the JWT)
    STS->>OIDC: validate signature via JWKS; check iss + aud + sub
    OIDC-->>STS: token valid (signed by this trusted cluster)
    STS-->>SDK: TEMPORARY creds for the SCOPED role (expire ~1h, auto-refresh)
    SDK->>OBJ: GetObject with the temporary creds
    OBJ-->>SDK: object bytes (only what the role's least-priv policy allows)
    Note over STS,OBJ: No static key anywhere. Scope = catalog-sa's role ONLY;<br/>orders-sa would get a DIFFERENT role.
```

### Diagram B — IRSA vs Pod Identity vs GKE WI vs AKS WI (ASCII)

```
 SAME FEDERATION, FOUR CONFIG SURFACES ─────────────────────────────────────

  aspect            EKS IRSA          EKS Pod Identity   GKE Workload Id   AKS Workload Id
  ───────────────────────────────────────────────────────────────────────────────────
  cluster side      OIDC provider     EKS Pod Identity   OIDC issuer       OIDC issuer
   prerequisite      registered in     Agent (add-on)     (--workload-pool) (--enable-
                      IAM (withOIDC)    on the cluster                        oidc-issuer)
  trust object      IAM role trust    PodIdentity-       IAM policy bind   Entra app/MI
                     policy (web-       Association        KSA->GSA  (or     FEDERATED
                     identity, sub/     (SA -> IAM role,   direct KSA       CREDENTIAL
                     aud condition)     no OIDC bookkeep)  principal)        (iss/sub)
  SA annotation     eks.amazonaws.com  (none — assoc is   iam.gke.io/gcp-   azure.workload
                     /role-arn          API-side)          service-account   .identity/...
  pod opt-in        webhook (auto)     agent (auto)       (auto via KSA)    label: azure.
                                                                             workload.iden-
                                                                             tity/use:true
  credential        STS AssumeRole-    same, via agent    STS token         Entra token
   path              WithWebIdentity                       exchange          exchange
  scope unit        per ServiceAcct    per ServiceAcct    per KSA           per ServiceAcct
   (= per workload)  (catalog-sa !=     (assoc per SA)     (KSA->GSA)        (fed cred per
                      orders-sa)                                              SA)
  best when         existing IRSA;     NEW setups; many   GKE-native;       AKS-native;
                      fine-grained       clusters/accts;    GSA reuse or      Entra-centric
                      OIDC control       less bookkeeping   direct grants
  ───────────────────────────────────────────────────────────────────────────────────
  ALL FOUR: projected audience-bound SA token (Part 05 ch.01) -> cloud STS ->
  TEMPORARY, per-SA, least-privilege creds. NONE store a static key. The
  Kubernetes-side artifact is just an ANNOTATED ServiceAccount (+ pod opt-in).
  ANTI-PATTERN all four replace: a static key in a Secret, or the NODE's role.
```

## Hands-on with the Bookstore

**Assumed working directory: the guide repo root (`full-guide/`).** This
chapter adds **no canonical manifests** — it shows the SA *annotation* each
provider needs and the IAM/role side, as **illustrative** overlays on the
existing `catalog-sa`/`orders-sa` from
[`05-serviceaccounts-rbac.yaml`](../examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml)
(Part 05 ch.01). It does **not** edit that canonical file. The goal: give
`catalog` read access to a cloud bucket with **zero static keys**.

> **Honest cloud-account note (read first).** The IAM role/policy/federated-
> credential commands need a real cloud account + a managed cluster's OIDC
> issuer. The **Kubernetes side is runnable on kind today** and is
> *byte-identical* on the cloud: the annotated ServiceAccount and the pod
> opt-in dry-run cleanly anywhere; only the cloud STS exchange is what the
> account adds. Placeholders only.

### 1. The problem, made concrete (runnable: prove no key exists)

`catalog` currently has no cloud access and **no static key** — exactly the
clean starting state we want to *preserve* while adding cloud access:

```sh
# from the repo root (full-guide/) — bring catalog up (any cluster; kind ok):
kubectl apply -f examples/bookstore/raw-manifests/00-namespace.yaml
kubectl apply -f examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml
# catalog-sa has automountServiceAccountToken:false and NO cloud annotation yet.
kubectl get sa catalog-sa -n bookstore -o yaml | grep -A3 'annotations:' || echo "no annotations yet"
# There is NO Secret with a cloud key anywhere in the app — verify (stays true):
kubectl get secrets -n bookstore        # db-credentials (DEMO) only; NO cloud key
```

The objective: add bucket read for `catalog` **without** ever introducing a
cloud key into that list.

### 2a. EKS — IRSA (lead path: OIDC provider + role trust + SA annotation)

The cluster's OIDC provider was registered at create time
([ch.02](02-provisioning-and-iac.md): `iam.withOIDC: true`). Create an IAM
role whose **trust policy** federates the cluster issuer for *exactly*
`catalog-sa`, attach a least-privilege bucket policy, then annotate the SA:

```sh
# (illustrative — your account 123456789012, region us-east-1, $CLUSTER_NAME)
OIDC=$(aws eks describe-cluster --name $CLUSTER_NAME \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's~https://~~')

# Trust policy: ONLY catalog-sa in ns bookstore, ONLY the STS audience.
cat > trust.json <<EOF
{ "Version": "2012-10-17", "Statement": [{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/$OIDC" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": { "StringEquals": {
    "$OIDC:aud": "sts.amazonaws.com",
    "$OIDC:sub": "system:serviceaccount:bookstore:catalog-sa" } } }] }
EOF
aws iam create-role --role-name bookstore-catalog-s3 \
  --assume-role-policy-document file://trust.json
# Least-privilege: READ ONLY, ONE bucket prefix (not s3:* , not all buckets):
aws iam put-role-policy --role-name bookstore-catalog-s3 \
  --policy-name read-covers --policy-document '{"Version":"2012-10-17",
   "Statement":[{"Effect":"Allow","Action":["s3:GetObject"],
   "Resource":"arn:aws:s3:::your-org-book-covers/*"}]}'
```

The **only** Kubernetes-side change — an annotation on the *existing*
`catalog-sa` (shown as an illustrative overlay; the canonical
`05-serviceaccounts-rbac.yaml` is **not** edited):

```yaml
# illustrative patch — what IRSA needs on the SA (nothing else in the app changes)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-sa
  namespace: bookstore
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/bookstore-catalog-s3
# NOTE: precise mechanics. The IRSA mutating webhook (Pod Identity webhook)
# fires on the SA ANNOTATION above and injects its OWN projected
# aws-iam-token volume + AWS_* env REGARDLESS of automountServiceAccountToken
# (that flag only governs the *default* kube-API SA-token volume, a separate
# thing). So IRSA still works with automountServiceAccountToken:false. The
# real requirement is that the webhook fires (annotation present, namespace
# not webhook-excluded). The base catalog-sa keeps automount:false because the
# BASE app makes no API/cloud calls; a cloud-using variant just ADDS the
# annotation — a deliberate, scoped change. Don't rely on automount toggling
# to enable/disable cloud creds; the annotation does.
```

```sh
kubectl annotate sa catalog-sa -n bookstore \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/bookstore-catalog-s3
kubectl rollout restart deployment/catalog -n bookstore   # re-project the token
# The mutating webhook now injects AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE
# + the projected token volume. The AWS SDK picks them up automatically — the
# app code is UNCHANGED, and there is STILL no key in any Secret.
```

### 2b. EKS — Pod Identity (the newer model: an association, no annotation)

Pod Identity removes the OIDC-provider + annotation bookkeeping: install the
**EKS Pod Identity Agent** add-on, then create a **PodIdentityAssociation**
mapping the SA to the role (same least-privilege role/policy as 2a):

```sh
eksctl create addon --cluster $CLUSTER_NAME --name eks-pod-identity-agent
aws eks create-pod-identity-association --cluster-name $CLUSTER_NAME \
  --namespace bookstore --service-account catalog-sa \
  --role-arn arn:aws:iam::123456789012:role/bookstore-catalog-s3
# NO SA annotation, NO OIDC-provider trust block — the association IS the trust.
# The agent supplies creds to Pods using catalog-sa. Same zero-static-key result.
```

### 2c. GKE — Workload Identity (KSA ↔ Google service account)

```sh
# Bind the Kubernetes SA to a Google service account (GSA) with bucket read:
gcloud iam service-accounts create bookstore-catalog
gcloud storage buckets add-iam-policy-binding gs://your-org-book-covers \
  --member="serviceAccount:bookstore-catalog@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"          # READ ONLY, this bucket
gcloud iam service-accounts add-iam-policy-binding \
  bookstore-catalog@$PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT.svc.id.goog[bookstore/catalog-sa]"
kubectl annotate sa catalog-sa -n bookstore \
  iam.gke.io/gcp-service-account=bookstore-catalog@$PROJECT.iam.gserviceaccount.com
```

### 2d. AKS — Workload Identity (a federated credential on an Entra identity)

```sh
ISSUER=$(az aks show -g $RG -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv)
az identity create -g $RG -n bookstore-catalog
CID=$(az identity show -g $RG -n bookstore-catalog --query clientId -o tsv)
# Federate the cluster issuer for EXACTLY catalog-sa:
az identity federated-credential create --identity-name bookstore-catalog -g $RG \
  --name catalog-fed --issuer "$ISSUER" \
  --subject system:serviceaccount:bookstore:catalog-sa \
  --audience api://AzureADTokenExchange
# (grant the identity 'Storage Blob Data Reader' on the container — least priv)
kubectl annotate sa catalog-sa -n bookstore azure.workload.identity/client-id=$CID
# Pods opt in with the pod/SA label azure.workload.identity/use: "true".
```

### 3. Prove the scope holds (the security property — runnable reasoning)

The boundary is the SA's `sub` claim, so `orders` cannot use `catalog`'s
access and vice-versa — the [Part 05
ch.01](../05-security/01-authn-authz-rbac.md) per-workload least-privilege
rule, now at cloud scope:

```sh
# orders-sa has NO cloud annotation/association/binding -> its Pods get NO
# cloud creds at all (the federation only matches sub=...:catalog-sa):
kubectl get sa orders-sa -n bookstore -o yaml | grep -E 'role-arn|gcp-service|client-id' \
  || echo "orders-sa: NO cloud identity (correct — scope is per-SA)"
# A compromised catalog Pod can do ONLY catalog's role (s3:GetObject on ONE
# bucket prefix) — not write, not delete, not other buckets, not orders' scope.
# This is the SAME property as `kubectl auth can-i --list --as=...:catalog-sa`
# in Part 05 ch.01, extended across the cloud trust boundary.
```

> **Lineage note.** This builds directly on
> [`05-serviceaccounts-rbac.yaml`](../examples/bookstore/raw-manifests/05-serviceaccounts-rbac.yaml)
> ([Part 05 ch.01](../05-security/01-authn-authz-rbac.md)) — the SAs already
> exist and are already one-per-workload; cloud identity is *one annotation*
> (or an API-side association) on top, **canonical file unedited**. The
> in-cluster RBAC of Part 05 ch.01 (what a SA may do *to the Kubernetes API*)
> and cloud identity (what it may do *to the cloud*) are orthogonal layers on
> the same ServiceAccount — both least-privilege, both per-workload.

## How it works under the hood

- **The projected token is the [Part 05 ch.01](../05-security/01-authn-authz-rbac.md)
  bound token, re-aimed at the cloud.** The kubelet uses the **TokenRequest**
  API to mint a ServiceAccount JWT that is **audience-scoped** (the cloud
  STS), **time-limited** (≈1h, auto-rotated before expiry), and **bound to the
  Pod** (invalid once the Pod is gone). It is mounted at a projected-volume
  path. The cloud SDK's default credential chain knows to look there (via the
  injected `AWS_WEB_IDENTITY_TOKEN_FILE` / `GOOGLE_APPLICATION_CREDENTIALS`
  external-account file / Azure env) — which is why **the app code does not
  change**: the SDK does the exchange transparently.
- **The trust is `iss` + `aud` + `sub`, and it fails closed.** The cloud
  validates the JWT's signature against the cluster's **public JWKS** (fetched
  from the registered OIDC **`iss`**uer), then checks **`aud`** equals the
  expected audience and **`sub`** equals
  `system:serviceaccount:<NS>:<SA>`. All three must match the IAM
  trust/condition (IRSA), the association (Pod Identity), the IAM binding
  member (GKE), or the federated credential (AKS). A wrong namespace, a typo'd
  SA name, a missing `withOIDC`, or the wrong audience → the STS call is
  *denied*, not silently degraded. (Common errors:
  `WebIdentityErr`/`AccessDenied` on the STS call, or `An error occurred …
  Not authorized to perform sts:AssumeRoleWithWebIdentity` — almost always a
  `sub`/`aud`/issuer mismatch.)
- **Why this beats a static key — structurally.** A static key is a *bearer
  secret*: possession = access, forever, anywhere. A federated credential is
  *minted on demand from an identity the cluster vouches for, scoped to one
  SA, and expiring in an hour*. There is **no secret at rest** (nothing to
  encrypt, leak, commit, or rotate), the **blast radius is one workload's
  role**, and **revocation is immediate** (delete the trust/association/
  binding — no key to hunt down). This is precisely why [Part 05
  ch.04](../05-security/04-secrets-and-cluster-hardening.md)'s "no long-lived
  secrets" principle is *enforced by architecture* here, not by policy.
- **Node identity vs Pod identity — the boundary that matters.** The node's
  instance role/managed-identity is *also* an IAM principal; if it has the S3
  permission, **every Pod on the node** can use it via the instance metadata
  endpoint — the cloud form of the shared-`default`-SA anti-pattern ([Part 05
  ch.01](../05-security/01-authn-authz-rbac.md)). Workload identity scopes to
  the **Pod's SA** instead. Hardening implication: keep the **node role
  minimal** (only what the kubelet/CNI/CSI need) and **block Pod access to the
  instance metadata service** (IMDSv2 hop-limit / a NetworkPolicy `ipBlock`
  deny to `169.254.169.254` — [Part 02 ch.06](../02-networking/06-network-policies.md))
  so a Pod *must* use its scoped SA identity and cannot steal the node's.
- **IRSA vs Pod Identity, mechanically.** IRSA: a per-cluster IAM **OIDC
  provider** + a per-role **trust policy** with `sub`/`aud` conditions + a
  mutating webhook that injects the env/volume from the SA's `role-arn`
  annotation. Pod Identity: an on-node **agent** + an API-side
  **PodIdentityAssociation** (SA→role) — no OIDC provider per cluster, no
  annotation, no trust-policy editing, and roles are reusable across clusters
  by association. Pod Identity is the newer, lower-bookkeeping model
  (especially at many-clusters/accounts scale); IRSA remains widely deployed
  and gives finer OIDC-condition control. **GKE WI** uses Google's IAM
  binding (`roles/iam.workloadIdentityUser` on the GSA for the
  `PROJECT.svc.id.goog[ns/ksa]` member), with newer **direct** KSA-principal
  grants removing the GSA hop. **AKS WI** uses an Entra app/managed-identity
  **federated credential** keyed on `(issuer, subject)`. Four surfaces, the
  same `iss`/`aud`/`sub` federation underneath.
- **Scope is per-SA, which is *why* one-SA-per-workload (Part 05 ch.01)
  pays off here.** Because the trust matches the `sub` claim, the unit of
  cloud authorization is the ServiceAccount. The Bookstore already has
  `catalog-sa`, `orders-sa`, `storefront-sa`, … one per workload ([Part 05
  ch.01](../05-security/01-authn-authz-rbac.md)) — so cloud least-privilege is
  *free*: annotate only the SAs that need cloud, each with its own minimal
  role. A shared SA would force a shared (over-broad) cloud role — the exact
  reason that anti-pattern was rejected in Part 05.

## Production notes

> **In production: never put a static cloud key in a cluster — use workload
> identity.** No `AWS_ACCESS_KEY_ID` Secret, no service-account JSON file, no
> Azure client secret. Use **IRSA / EKS Pod Identity / GKE Workload Identity /
> AKS Workload Identity** so every credential is short-lived, per-SA, and
> minted on demand. A long-lived cloud key in a Secret is base64
> ([Part 03 ch.02](../03-config-and-storage/02-secrets.md)), leaks via
> `helm get values`/RBAC ([Part 05 ch.01](../05-security/01-authn-authz-rbac.md)),
> and is the highest-value steal in the cluster.

> **In production: scope the role to one workload and the minimum actions.**
> The Bookstore's one-SA-per-workload model ([Part 05 ch.01](../05-security/01-authn-authz-rbac.md))
> means `catalog`'s role is `s3:GetObject` on **one bucket prefix** — not
> `s3:*`, not `*` resources, not shared with `orders`. The federation boundary
> is the SA's `sub`; a broad role on a shared SA throws that away. Treat a
> cloud-IAM policy change like an RBAC change: reviewed, audited, minimal.

> **In production: block the node metadata endpoint and keep the node role
> tiny.** Workload identity is undermined if a Pod can still reach
> `169.254.169.254` and assume the *node's* role. Enforce IMDSv2 with a low
> hop limit and/or a NetworkPolicy `ipBlock` denying the metadata CIDR
> ([Part 02 ch.06](../02-networking/06-network-policies.md)); grant the node
> role only kubelet/CNI/CSI essentials. Pod identity scoping is only real if
> the node-identity escape is closed.

> **In production: get `iss`/`aud`/`sub` exactly right — it fails closed.**
> The cluster OIDC issuer must be enabled **at create time**
> ([ch.02](02-provisioning-and-iac.md)); the trust/association/binding
> must match the **exact** `system:serviceaccount:<NS>:<SA>` and the **exact**
> audience. A namespace/SA typo or a missing `withOIDC` is the most common
> failure (`AccessDenied`/`WebIdentityErr` on the STS call) — and it is a
> *good* failure (deny, not silent over-grant). (For IRSA the limiting factor
> is that the **webhook fires** — the annotation is present and the namespace
> isn't webhook-excluded; the webhook injects its own token volume regardless
> of `automountServiceAccountToken`, so that flag is *not* what enables/
> disables cloud creds.)

> **In production: prefer the lower-bookkeeping model at scale, but be
> consistent.** EKS **Pod Identity** removes per-cluster OIDC-provider and
> annotation/trust-policy bookkeeping (associations are reusable across
> clusters) — easier for many clusters/accounts; **IRSA** gives finer OIDC
> conditions and is fine where already adopted. GKE direct-principal grants
> remove the GSA hop. Pick one model per platform and standardise — mixed
> models are an audit and debugging tax.

> **In production: rotate by deleting trust, not by rotating keys (there are
> none).** Revoking a workload's cloud access is "delete the IAM
> role/association/binding/federated-credential" — instantaneous, no key to
> find. This is the operational payoff of having no secret at rest
> ([Part 05 ch.04](../05-security/04-secrets-and-cluster-hardening.md)); audit
> the trust objects, not a key inventory.

## Quick Reference

```sh
# EKS IRSA — OIDC provider exists (ch.02 withOIDC); role trust + SA annotation:
aws eks describe-cluster --name $CLUSTER_NAME --query cluster.identity.oidc.issuer
kubectl annotate sa <SA> -n <NS> eks.amazonaws.com/role-arn=arn:aws:iam::<ACCT>:role/<R>
# EKS Pod Identity — agent add-on + an association (no annotation):
eksctl create addon --cluster $CLUSTER_NAME --name eks-pod-identity-agent
aws eks create-pod-identity-association --cluster-name $CLUSTER_NAME \
  --namespace <NS> --service-account <SA> --role-arn arn:aws:iam::<ACCT>:role/<R>
# GKE Workload Identity:
kubectl annotate sa <SA> -n <NS> iam.gke.io/gcp-service-account=<GSA>@<PROJ>.iam.gserviceaccount.com
# AKS Workload Identity:
az identity federated-credential create --identity-name <ID> -g $RG --name <N> \
  --issuer "$ISSUER" --subject system:serviceaccount:<NS>:<SA> --audience api://AzureADTokenExchange
kubectl annotate sa <SA> -n <NS> azure.workload.identity/client-id=<CLIENT-ID>

# Verify NO static cloud key exists (it should never):
kubectl get secrets -n <NS>          # there must be NO cloud-key Secret
```

Minimal annotated-SA skeleton (the only Kubernetes-side artifact):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <APP>-sa
  namespace: <NS>
  annotations:
    # exactly ONE of these per provider (Pod Identity needs NONE — it's API-side):
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCT>:role/<SCOPED-ROLE>      # EKS IRSA
    iam.gke.io/gcp-service-account: <GSA>@<PROJ>.iam.gserviceaccount.com    # GKE WI
    azure.workload.identity/client-id: <ENTRA-CLIENT-ID>                    # AKS WI
# the IAM role/GSA/identity carries a LEAST-PRIVILEGE policy (one action, one
# resource); trust is scoped to system:serviceaccount:<NS>:<APP>-sa. No key.
```

Checklist:

- [ ] **No static cloud key** anywhere (no Secret, no env, no file) — workload
      identity only
- [ ] Trust/association/binding scoped to the **exact**
      `system:serviceaccount:<NS>:<SA>` and the **exact** audience
- [ ] The IAM role/GSA/identity policy is **least-privilege** (one action,
      one resource) — not `*`
- [ ] **One SA per workload** ([Part 05 ch.01](../05-security/01-authn-authz-rbac.md));
      annotate only those that need cloud; `catalog-sa` ≠ `orders-sa` scope
- [ ] OIDC issuer enabled **at cluster create** ([ch.02](02-provisioning-and-iac.md));
      for IRSA the **webhook fires** (annotation present, ns not
      webhook-excluded) — it injects its own token regardless of `automount`
- [ ] **Node metadata endpoint blocked** + node role minimal (no node-identity
      escape — [Part 02 ch.06](../02-networking/06-network-policies.md))
- [ ] Revocation tested = delete the trust object (no key inventory to chase)

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Explain in two sentences why IRSA is "zero stored secrets" — what replaces the AWS access key that lived in a Secret before?**
   <details><summary>Show answer</summary>

   The Pod's projected ServiceAccount token (a short-lived OIDC-signed JWT, audience `sts.amazonaws.com`) is exchanged at runtime via `sts:AssumeRoleWithWebIdentity` for temporary AWS credentials scoped to the IAM role declared in the SA annotation. No static key ever exists; the credential rotates automatically because the projected token rotates and AWS STS only issues short-lived sessions. The trust relationship is established once at cluster create (the OIDC provider) and per workload (the role trust policy), then it is keyless from then on.

   </details>

2. **The `catalog` Pod starts up but calls to S3 fail with "no identity found." `kubectl describe pod` shows the SA annotation is set and the projected token volume is mounted. What four things do you check?**
   <details><summary>Show answer</summary>

   (1) Is the EKS Pod Identity webhook running and is the Pod's namespace not excluded — without it, no `AWS_*` env vars and no token volume override are injected. (2) Does the IAM role trust policy's `Condition` on `oidc.eks...:sub` match the SA's fully-qualified name `system:serviceaccount:bookstore:catalog-sa`? (3) Is the audience in the trust policy `sts.amazonaws.com` and matches the projected token's audience? (4) Is the OIDC provider actually registered on the AWS side for this cluster's issuer URL? In practice the failure is almost always (2) (wrong namespace/SA in the `sub`) or (4) (cluster recreated without re-registering the issuer).

   </details>

3. **You are migrating from IRSA to EKS Pod Identity. Which guarantees you preserve and which mechanics change?**
   <details><summary>Show answer</summary>

   Preserved: per-workload least-privilege, no static keys, short-lived credentials, RBAC-scopable. Changed: instead of an OIDC trust policy and a webhook-mutated token volume, you create an EKS `PodIdentityAssociation` linking namespace+SA to an IAM role, and an on-node agent (the EKS Pod Identity Agent) serves credentials over a unix socket via the AWS SDK's container-credentials provider. The cluster no longer needs an OIDC issuer URL on every IAM role's trust policy, which makes cross-account and multi-cluster role reuse cleaner. The Pod's SDK behavior is identical; only the credential source changes.

   </details>

4. **Hands-on: create an IRSA role that grants `s3:GetObject` on one prefix, annotate a Pod's SA, and verify with `aws s3 ls` from inside the Pod. Then change the audience in the trust policy from `sts.amazonaws.com` to `wrong-audience`. What error do you see?**
   <details><summary>What you should see</summary>

   The exchange fails with `InvalidIdentityToken: Incorrect token audience` from STS. The Pod's `AWS_WEB_IDENTITY_TOKEN_FILE` still exists and the token is still issued, but STS rejects the assume-role call because the projected token's `aud` claim does not match the trust policy's expected audience. This is the most common audience/trust mismatch class of failure — and the lesson is that the audience is part of the trust contract, not a free string.

   </details>

5. **GKE Workload Identity uses a "Google Service Account" (GSA) bound to a Kubernetes Service Account (KSA). Why does Google not use the same OIDC-role flow as AWS?**
   <details><summary>Show answer</summary>

   GKE relies on the GKE metadata server intercepting `metadata.google.com` calls from the Pod and impersonating the bound GSA at the GCP IAM layer. The binding is `iam.workloadIdentityUser` granted to `serviceAccount:PROJECT.svc.id.goog[NS/KSA]`. This is conceptually the same OIDC-federation idea (the cluster has a workload identity pool tied to its OIDC issuer) but the GKE control plane handles the credential exchange transparently — there is no `AssumeRoleWithWebIdentity`-style call in user code. The Pod just hits the metadata server and gets temporary GSA credentials. Same outcome, simpler Pod-side ergonomics, GCP-specific lock-in.

   </details>

## Further reading

- **Rosso et al., _Production Kubernetes_, ch.10 — Identity** (workload
  identity, token mechanics, and bridging Kubernetes identity to cloud IAM in
  production — the production framing for this whole chapter) and **ch.7 —
  Secret Management** (why a static cloud key in a Secret is the wrong model).
- **Ibryam & Huß, _Kubernetes Patterns_ 2e, ch.26 — Access Control** (the
  authentication/authorization model and least-privilege identity as a
  pattern, extended here across the cloud trust boundary).
- Official: EKS IAM roles for service accounts (IRSA)
  <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>,
  EKS Pod Identities
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>, GKE
  Workload Identity
  <https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity>,
  and AKS Workload Identity
  <https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview>.
