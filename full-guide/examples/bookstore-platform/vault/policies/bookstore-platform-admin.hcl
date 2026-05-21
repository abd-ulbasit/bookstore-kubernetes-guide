# Bookstore Platform v2 — Part 15 ch.05: admin Vault policy for the
# tenant-onboarding flow.
#
# The Crossplane Composition (Part 13 ch.02) onboarding a new tenant needs
# to: create a per-tenant KV mount path, create a per-tenant policy
# (templated from `bookstore-platform-app.hcl`), bind the per-tenant
# Kubernetes auth role (see `auth-k8s/role-bookstore-platform.yaml`), and
# configure the per-tenant database engine role. This policy grants
# exactly that surface — no more.
#
# IT IS NOT THE ROOT TOKEN. The root token bootstraps Vault; this policy
# is bound to the **platform's Terraform identity** (an IRSA role or a
# JWT-bound service account whose token Terraform's `vault` provider
# exchanges via AppRole / OIDC; never a long-lived static token in CI).
# In the Phase 15-R Terraform tree, this admin policy is what the
# `vault_policy` resource for tenant onboarding attaches to.
#
# Apply (one-time bootstrap):
#   vault policy write bookstore-platform-admin \
#     examples/bookstore-platform/vault/policies/bookstore-platform-admin.hcl
#
# Verify:
#   vault policy read bookstore-platform-admin

# ── Tenant KV management — create/read/update/delete only under the
# platform's own KV mount ─────────────────────────────────────────────────
# Note the path scope: `secret/data/bookstore-platform/*` — the admin role
# CANNOT read `secret/data/<OTHER-MOUNT-PATH>/*`. The platform shares one
# Vault instance with other teams; this policy never reaches outside its
# subtree. (Sibling teams have their own admin policies bound to their
# own subtrees — the same isolation discipline as Part 13 ch.02's per-
# tenant namespace.)
path "secret/data/bookstore-platform/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "secret/metadata/bookstore-platform/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage per-tenant policies — create/update only those whose name starts
# with `bookstore-platform-app-`. Deletion is intentionally NOT granted:
# a deleted policy un-authenticates every workload still bound to it; the
# off-boarding flow renames it to `-deprecated` first, drains workloads,
# then a human deletes it. This is the Part 15 ch.07 rollback discipline
# applied at the secrets layer.
path "sys/policies/acl/bookstore-platform-app-*" {
  capabilities = ["create", "read", "update", "list"]
}

# Manage per-tenant Kubernetes auth roles. The role binds a K8s SA to
# the tenant's policy; creating it is the onboarding step that wires
# the SA → Vault token → secret read chain.
path "auth/kubernetes/role/bookstore-platform-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage per-tenant database engine roles (the dynamic-secret SQL
# template). The connection-config (which Postgres to connect to) is
# admin-only and managed via Terraform; per-tenant ROLES live here.
path "database/roles/bookstore-platform-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# ── Visibility (read-only) on the auth method config and engine config so
# the Composition can verify state before creating things ────────────────
path "auth/kubernetes/config" {
  capabilities = ["read"]
}

path "database/config/bookstore-platform-postgres" {
  capabilities = ["read"]
}

# ── Lease management for tenant offboarding ──────────────────────────────
# When a tenant is offboarded, the Composition revokes all leases under
# the tenant's prefix (faster than waiting for natural expiry). The
# `lookup` capability lets the offboarder find the leases first.
path "sys/leases/lookup" {
  capabilities = ["update"]
}

path "sys/leases/revoke-prefix/database/creds/bookstore-platform-*" {
  capabilities = ["update"]
}

# ── DENY (documentation of intent) ───────────────────────────────────────
#
#   NOT GRANTED:
#     - sys/auth/* (mounting/unmounting auth methods — root only)
#     - sys/mounts/* (mounting/unmounting secrets engines — root only)
#     - sys/seal, sys/unseal, sys/step-down (HA control — root only)
#     - secret/data/<OTHER-MOUNT-PATH>/*  (any non-bookstore-platform path)
#     - auth/kubernetes/role/<OTHER-TEAM-*> (any non-prefixed role name)
#     - sys/policies/acl/*  (cannot edit OTHER teams' policies)
