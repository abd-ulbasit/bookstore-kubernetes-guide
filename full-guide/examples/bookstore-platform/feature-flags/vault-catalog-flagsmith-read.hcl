# Bookstore Platform, Part 15 ch.08: the catalog reads one key, the Flagsmith
# server-side environment key. The catalog's Vault role (bound to the catalog
# ServiceAccount in bookstore-platform-catalog) gets this policy only.
path "secret/data/bookstore-platform/catalog/flagsmith-sdk" {
  capabilities = ["read"]
}

path "secret/metadata/bookstore-platform/catalog/flagsmith-sdk" {
  capabilities = ["read"]
}
