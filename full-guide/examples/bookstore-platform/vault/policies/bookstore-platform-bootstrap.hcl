# Bookstore Platform, Part 15 ch.05: the one-time bootstrap identity.
#
# Mounting the database engine, enabling the Kubernetes auth method and
# writing the admin policy need paths the admin policy does not grant (its
# DENY list says so). Bind this policy to a token that the platform operator
# mints with a one-hour TTL, use it for the bootstrap steps, then revoke it:
#   vault token revoke -self
# Never bind it to a workload, a CI job or a person's daily token.
#
# Root writes this policy once, before any bootstrap token exists:
#   vault policy write bookstore-platform-bootstrap \
#     examples/bookstore-platform/vault/policies/bookstore-platform-bootstrap.hcl

# vault auth enable kubernetes; vault auth list
path "sys/auth/kubernetes" {
  capabilities = ["create", "update", "read"]
}
path "sys/auth" {
  capabilities = ["read"]
}

# vault write auth/kubernetes/config (the Vault-side TokenReview settings)
path "auth/kubernetes/config" {
  capabilities = ["create", "update", "read"]
}

# vault secrets enable -path=database database; vault secrets list
path "sys/mounts/database" {
  capabilities = ["create", "update", "read"]
}
path "sys/mounts" {
  capabilities = ["read"]
}

# vault policy write bookstore-platform-admin (step 3 of the chapter)
path "sys/policies/acl/bookstore-platform-admin" {
  capabilities = ["create", "update", "read"]
}

# postgres-rotate.sh bootstrap: the engine config and the dynamic role
path "database/config/bookstore-platform-postgres-*" {
  capabilities = ["create", "update", "read"]
}
path "database/roles/bookstore-platform-*" {
  capabilities = ["create", "update", "read"]
}
