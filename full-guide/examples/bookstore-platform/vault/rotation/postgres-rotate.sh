#!/usr/bin/env bash
# Bookstore Platform v2 — Part 15 ch.05: dynamic Postgres credential
# rotation via Vault's database secrets engine.
#
# This script DEMONSTRATES the dynamic-secrets pattern. In production, the
# rotation is automatic: Vault mints a new Postgres role per ExternalSecret
# read, the lease expires after `default_ttl`, Vault drops the role via the
# revocation SQL. No human runs this script in steady state; the script
# exists for (a) the chapter walkthrough, (b) emergency rotation forcing,
# and (c) the validation step that proves the pattern works end-to-end.
#
# WHAT THIS SCRIPT DOES:
#  1. Configures the Vault database engine to talk to the tenant's CNPG
#     Postgres cluster (one-time bootstrap; in production this lives in the
#     Crossplane Composition's Terraform output, not in a shell script).
#  2. Defines a per-tenant `bookstore-platform-acme-books` role with a SQL
#     template that CREATEs a new Postgres role per request.
#  3. Forces an immediate rotation: reads a fresh credential from Vault and
#     asserts the new credential authenticates against Postgres.
#  4. Lists existing leases so an operator can see what is outstanding;
#     optionally revokes a specific lease for emergency rotation.
#
# Usage:
#   export VAULT_ADDR=https://vault-active.vault.svc.cluster.local:8200
#   export VAULT_TOKEN=<a token with the bookstore-platform-admin policy>
#   ./postgres-rotate.sh bootstrap    # one-time setup
#   ./postgres-rotate.sh rotate       # force a new credential, validate
#   ./postgres-rotate.sh revoke <lease-id>
#
# This script is intentionally explicit (no clever bash). It is the kind of
# script that gets read in an incident at 3am.

set -euo pipefail

TENANT="${TENANT:-acme-books}"
ROLE_NAME="bookstore-platform-${TENANT}"
DB_CONFIG_NAME="bookstore-platform-postgres-${TENANT}"
PG_SVC="postgres.bookstore-platform-${TENANT}.svc.cluster.local"
PG_DB="bookstore"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"

# The admin password is read from the cluster's bootstrap Secret rather
# than baked into the script. In production this Secret was itself
# materialized from Vault — circular, but the bootstrap Secret is what
# lets Vault talk to Postgres in the first place. Phase 15-R Terraform
# stamps it directly into Vault's database engine config, not the cluster.
require_var() {
  if [ -z "${!1:-}" ]; then
    echo "ERROR: \$$1 is required" >&2
    exit 1
  fi
}

bootstrap() {
  require_var VAULT_ADDR
  require_var VAULT_TOKEN
  require_var PG_ADMIN_PASSWORD

  echo "[1/3] Enable database secrets engine (idempotent — ok if already enabled)..."
  vault secrets enable -path=database database 2>/dev/null || true

  echo "[2/3] Configure connection to tenant Postgres ${PG_SVC}..."
  vault write "database/config/${DB_CONFIG_NAME}" \
    plugin_name=postgresql-database-plugin \
    allowed_roles="${ROLE_NAME}" \
    connection_url="postgresql://{{username}}:{{password}}@${PG_SVC}:5432/${PG_DB}?sslmode=require" \
    username="${PG_ADMIN_USER}" \
    password="${PG_ADMIN_PASSWORD}"

  echo "[3/3] Define dynamic role with SQL CREATE/REVOKE statements..."
  vault write "database/roles/${ROLE_NAME}" \
    db_name="${DB_CONFIG_NAME}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\"; GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
    revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO ${PG_ADMIN_USER}; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

  echo "Bootstrap complete. The catalog ExternalSecret can now request"
  echo "dynamic creds via 'vault read database/creds/${ROLE_NAME}'."
}

rotate() {
  require_var VAULT_ADDR
  require_var VAULT_TOKEN

  echo "[1/2] Reading a fresh dynamic credential from Vault..."
  # The vault read MAKES Vault CREATE a new Postgres role. The output
  # carries: username, password, lease_id, lease_duration.
  vault read -format=json "database/creds/${ROLE_NAME}" > /tmp/vault-creds.json
  local lease_id
  lease_id=$(jq -r .lease_id < /tmp/vault-creds.json)
  local username
  username=$(jq -r .data.username < /tmp/vault-creds.json)

  echo "  Minted Postgres role: ${username}"
  echo "  Lease ID:             ${lease_id}"
  echo "  Lease duration:       $(jq -r .lease_duration < /tmp/vault-creds.json)s"

  echo "[2/2] Validating the new credential against ${PG_SVC}..."
  # PGPASSWORD via env so it does not appear in `ps`. We pipe the password
  # straight from the JSON; nothing about it is persisted on disk beyond
  # the temp file (which is rm'd below).
  PGPASSWORD="$(jq -r .data.password < /tmp/vault-creds.json)" \
    psql --host="${PG_SVC}" --port=5432 --username="${username}" \
         --dbname="${PG_DB}" -c "SELECT 1 AS rotation_check" > /dev/null
  echo "  OK — new role authenticated and queried Postgres."

  # NEVER leave the creds on disk past validation. Even on temp filesystems,
  # the Part 03 ch.02 "secrets are projections" rule applies.
  shred --remove /tmp/vault-creds.json 2>/dev/null || rm -f /tmp/vault-creds.json

  echo "Rotation complete. The credential lives in Vault under lease"
  echo "${lease_id}; it will be auto-revoked after default_ttl."
}

revoke() {
  require_var VAULT_ADDR
  require_var VAULT_TOKEN
  local lease_id="${1:-}"
  if [ -z "${lease_id}" ]; then
    echo "ERROR: revoke requires a lease-id argument" >&2
    echo "       List with: vault list sys/leases/lookup/database/creds/${ROLE_NAME}" >&2
    exit 1
  fi
  echo "Revoking lease ${lease_id}..."
  vault lease revoke "${lease_id}"
  echo "Vault ran the revocation SQL; the Postgres role is now DROPped."
}

case "${1:-help}" in
  bootstrap) bootstrap ;;
  rotate)    rotate ;;
  revoke)    shift; revoke "$@" ;;
  help|*)
    cat <<EOF
Usage: $0 <command>

Commands:
  bootstrap          One-time setup: enable engine, configure connection,
                     create per-tenant role. Requires PG_ADMIN_PASSWORD env.
  rotate             Mint a fresh dynamic credential, validate against
                     Postgres, never persist to disk.
  revoke <lease-id>  Emergency revoke of a specific lease. The Postgres
                     role is DROPped by Vault's revocation SQL.

Environment:
  TENANT             Tenant name (default: acme-books)
  VAULT_ADDR         Vault address (required)
  VAULT_TOKEN        Token with bookstore-platform-admin policy (bootstrap)
                     OR with the tenant policy (rotate/revoke)
  PG_ADMIN_PASSWORD  Postgres admin password (bootstrap only)
EOF
    exit 1
    ;;
esac
