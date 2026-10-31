# Bookstore Platform, Part 15 ch.08: read-only access to the Flagsmith secrets.
# The flagsmith namespace's SecretStore logs in with its own Vault role
# (bound to the flagsmith-api ServiceAccount) and gets this policy only.
path "secret/data/feature-flags/flagsmith/*" {
  capabilities = ["read"]
}

path "secret/metadata/feature-flags/flagsmith/*" {
  capabilities = ["read"]
}
