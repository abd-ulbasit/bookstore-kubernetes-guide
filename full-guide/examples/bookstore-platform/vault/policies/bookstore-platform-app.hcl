# Bookstore Platform v2 — Part 15 ch.05: app-tier Vault policy.
#
# This is the READ-ONLY policy bound to every tenant workload's Kubernetes
# service account (via the `kubernetes` auth method role in
# `auth-k8s/role-bookstore-platform.yaml`). It is the production cousin of
# Part 11 ch.05's dev-mode `bookstore-ro` policy — tenant-scoped, additive-
# only, and the only policy a normal application pod ever needs.
#
# The Composition (Part 13 ch.02) writes the tenant name into a templated
# copy of this policy at onboarding time — `<TENANT>` here is a placeholder
# the Crossplane Composition or the Vault Terraform provider replaces with
# the actual tenant name (e.g. `acme-books`). The Composition produces one
# policy per tenant so tenants cannot read each other's paths — the Vault
# equivalent of the per-tenant RBAC + NetworkPolicy in Part 13 ch.02.
#
# Apply (using vault CLI; root token / admin policy required):
#   sed 's/<TENANT>/acme-books/g' \
#     examples/bookstore-platform/vault/policies/bookstore-platform-app.hcl \
#     | vault policy write bookstore-platform-app-acme-books -
#   vault policy list | grep bookstore-platform-app-
#
# Verify (after onboarding):
#   vault policy read bookstore-platform-app-acme-books
#
# Production fits in a single screen. No * wildcards on `secret/*`, no
# `sudo` capability, no list-all-secrets, no path that crosses tenants.

# ── Static KV v2 — read only the tenant's own KV mount path ──────────────
# Read tenant secrets (the data path; KV v2 namespaces under /data/).
path "secret/data/bookstore-platform/<TENANT>/*" {
  capabilities = ["read"]
}

# Read KV v2 metadata so ESO can detect version changes (NOT list — list
# would let the tenant enumerate every key under the mount; read of an
# explicit path is enough for ESO's `refreshInterval` to pick up rotation).
path "secret/metadata/bookstore-platform/<TENANT>/*" {
  capabilities = ["read"]
}

# ── Dynamic database engine — read a per-tenant role ─────────────────────
# Reading this endpoint MAKES Vault mint a new short-lived Postgres role
# with the SQL in `database/roles/bookstore-platform-<TENANT>`. The role
# itself is created by the Composition / Terraform; the policy only grants
# the right to CALL it. Leases revoke the role on expiry — see
# `rotation/postgres-rotate.sh` for the dynamic-secret pattern in detail.
path "database/creds/bookstore-platform-<TENANT>" {
  capabilities = ["read"]
}

# ── Lease renewal / lookup (own leases only) ─────────────────────────────
# An ExternalSecret with a long refreshInterval may want to renew its
# lease rather than re-mint a credential. Vault scopes the {{identity.*}}
# template variables to the current token's identity, so this is
# self-only by construction (the policy authority on the lease is the
# entity that minted it).
path "sys/leases/renew" {
  capabilities = ["update"]
}

path "sys/leases/lookup" {
  capabilities = ["update"]
}

# ── DENY everything not listed above ─────────────────────────────────────
# Vault's policy model is default-deny: a path not listed is denied. The
# block below is documentation of intent (NOT a Vault primitive) — it
# spells out the things this policy does NOT grant, so a future editor
# adding a path knows what they would be widening.
#
#   NOT GRANTED:
#     - secret/data/bookstore-platform/<OTHER-TENANT>/*   (cross-tenant)
#     - secret/*  (any read at mount root — would leak structure)
#     - database/config/*  (the engine config itself — admin only)
#     - sys/policies/*  (read of policies — admin only)
#     - sys/auth/*  (auth methods — admin only)
#     - auth/kubernetes/login  (NOT listed — this is the path WHERE the
#       SA authenticates; Vault's `kubernetes` auth method does NOT
#       require the policy to grant `login` on itself, the auth method
#       gates it via the role binding; the bind happens at `vault write
#       auth/kubernetes/role/...`)
