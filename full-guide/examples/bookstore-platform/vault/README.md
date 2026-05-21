# `vault/` — Production secrets: Vault + ESO + rotation

This tree is the **production replacement** for Part 11 ch.05's dev-mode
Vault. It assumes the Phase 15-R Terraform tree has installed a real Vault
on EKS (HA mode, KMS auto-unseal, audit device, internal-only Service) and
shows the Kubernetes-side wiring: the per-tenant Vault policies, the
Kubernetes auth method role binding, the ESO ClusterSecretStore, a sample
tenant ExternalSecret, and a dynamic-Postgres rotation pattern.

Read Part 15 ch.05 (`../../../15-day-to-day-production-ops/05-production-
secrets-vault-eso.md`) first. The chapter walks this directory end-to-end.

| File | What it is | Applied via |
|------|------------|-------------|
| `policies/bookstore-platform-app.hcl` | Tenant-scoped READ-ONLY policy (Vault HCL). The Composition templates `<TENANT>` per tenant. | `vault policy write` (admin token) |
| `policies/bookstore-platform-admin.hcl` | Onboarding policy — create per-tenant policies, KV paths, auth roles. | `vault policy write` (root, bootstrap-only) |
| `auth-k8s/role-bookstore-platform.yaml` | Conceptual YAML for the `kubernetes` auth method role binding. **NOT a kubectl object** — see file header. | `vault write auth/kubernetes/role/...` |
| `cluster-secret-store.yaml` | ESO ClusterSecretStore — cluster-wide binding to Vault. **CRD-intrinsic dry-run.** | `kubectl apply` (after ESO installed) |
| `external-secret-sample.yaml` | Per-tenant ExternalSecret — pulls catalog DB creds from Vault into a Secret. **CRD-intrinsic dry-run.** | `kubectl apply` (after ESO installed) |
| `rotation/postgres-rotate.sh` | Dynamic Postgres credential rotation via Vault DB engine. Bootstrap + force-rotate + revoke. | `./rotation/postgres-rotate.sh bootstrap` |

## Pre-requisites

1. **Phase 15-R Terraform tree applied** — Vault HA on EKS, KMS-unsealed,
   audit-logged, internal-only Service `vault-active.vault.svc`. The dev-
   mode Vault from Part 11 ch.05 also works for local validation; only
   `cluster-secret-store.yaml`'s `server` URL changes.
2. **External Secrets Operator installed** — pinned Helm, own namespace
   (Part 11 ch.05 install step). The `ClusterSecretStore` and
   `ExternalSecret` CRDs are required before any `kubectl apply` of the
   files in this tree.
3. **Per-tenant K8s ServiceAccount exists** — the Crossplane Composition
   (Part 13 ch.02) stamps `bookstore-platform-eso` SA in each tenant ns.

## Bootstrap order (the three steps)

The order matters; reversing it leaves a window where ESO authenticates
to Vault but the policy does not yet exist (Vault returns "permission
denied" and ESO retries forever).

```sh
# 1. Vault unseal via KMS auto-unseal happens at pod-start, no manual step.
#    Verify: vault status (Sealed=false, HA Enabled=true).

# 2. Initialize the Kubernetes auth method ONCE per cluster (Vault side).
#    Phase 15-R Terraform did this; the manual fallback is:
kubectl -n vault exec -i vault-0 -- sh -c '
  export VAULT_TOKEN=<root or admin>
  vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"
'

# 3. Bind the first policy + role for a tenant (one-time per tenant; the
#    Composition automates this in production).
TENANT=acme-books
sed "s/<TENANT>/${TENANT}/g" policies/bookstore-platform-app.hcl \
  | vault policy write bookstore-platform-app-${TENANT} -
vault write auth/kubernetes/role/bookstore-platform-${TENANT} \
  bound_service_account_names=bookstore-platform-eso \
  bound_service_account_namespaces=bookstore-platform-${TENANT} \
  policies=bookstore-platform-app-${TENANT} ttl=15m max_ttl=1h
```

## The auth-method-vs-static-token trade-off

**Always use the Kubernetes auth method, never a static Vault token.**

A static `VAULT_TOKEN` baked into a Kubernetes Secret means every Pod
with access to that Secret has full Vault credentials valid until manual
revocation. A leaked token from a CI log, a Pod-exec, or an etcd dump is
catastrophic — Part 03 ch.02 / Part 05 ch.04 / Part 07 ch.04's "plaintext
in Git is plaintext forever" applies to Vault tokens just as much as to
DB passwords. The Kubernetes auth method binds Vault's trust to the K8s
SA token (which the kubelet rotates) plus the Vault policy (which
restricts what that identity can read); there is no long-lived secret to
leak. This is the same "identity, not stored credential" idea as Part 10
ch.03 cloud workload identity, applied to Vault.

## Rotation patterns (the four)

| Pattern | What rotates | How fast | When to use |
|---------|--------------|----------|-------------|
| **Static + `refreshInterval`** | The value in Vault KV; ESO re-syncs on schedule. | Bounded by `refreshInterval` (1h default). | Third-party API keys, vendor secrets, anything Vault cannot mint. |
| **Static + force-restart** | Rotate value in Vault → annotate the Deployment with `secret-rotation: <timestamp>` to force a rollout. | Immediate. | Emergency rotation of an env-var consumer (env vars are read at Pod-start only — Part 03 ch.02). |
| **Dynamic Postgres role** | Vault mints a new role per request; expires on lease. | Lease TTL (1h default). | The strongest. Tenant catalog DB credentials, internal service-to-service Postgres. |
| **Vault Agent template** | Sidecar re-renders a file in the Pod on Vault change. | Live (re-render); app must re-read file. | Apps that re-read config periodically (rare). PSA-restricted footgun applies. |

The platform's default is **dynamic Postgres roles for the catalog DB
password** (`external-secret-sample.yaml` + `rotation/postgres-rotate.sh`)
and **static + `refreshInterval=1h`** for everything else (vendor API
keys, OAuth client secrets). The dev/staging clusters use the same Vault
instance with different mount paths and different policies — never a
separate "non-prod" Vault, which would lull teams into testing rotation
in dev but skipping it in prod.

## Off-boarding (the reverse path)

```sh
TENANT=acme-books

# 1. Revoke all dynamic leases for the tenant — Postgres roles DROP.
vault lease revoke -prefix database/creds/bookstore-platform-${TENANT}

# 2. Disable the auth role; in-flight tokens expire at their TTL.
vault delete auth/kubernetes/role/bookstore-platform-${TENANT}

# 3. Rename the policy to deprecated (do NOT delete yet — the in-flight
#    tokens still reference it; rename ensures audit-log linkage stays
#    coherent and prevents accidental name re-use for a future tenant).
vault policy read bookstore-platform-app-${TENANT} \
  | vault policy write bookstore-platform-app-${TENANT}-deprecated -
vault policy delete bookstore-platform-app-${TENANT}

# 4. After 24h (longer than max_ttl), delete the deprecated policy and the
#    KV paths.
vault policy delete bookstore-platform-app-${TENANT}-deprecated
vault kv metadata delete -mount=secret bookstore-platform/${TENANT}/catalog/db-password
# (repeat for all keys under bookstore-platform/${TENANT}/*)
```

## Further reading

- Part 15 ch.05 — the chapter that owns this directory.
- Part 11 ch.05 — the dev-mode Vault foundations this builds on.
- Part 13 ch.02 — the Composition that stamps per-tenant policies / roles.
- Vault docs — Kubernetes auth method, database secrets engine, KV v2.
