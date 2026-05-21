# `app/auth/` — v2 storefront / admin SPA wiring (stub)

This directory is a stub. The platform's auth setup (Keycloak realm
imports + Istio RequestAuthentication + AuthorizationPolicy + IRSA-
annotated ServiceAccount) lives at
[`../../auth/`](../../auth/) — see ch.13.04.

What this directory holds in production (not in Phase 13b): the
storefront and admin SPA configuration that points at the Keycloak
realm:

- `storefront-spa-config.yaml` — a ConfigMap mounted into the storefront
  Pod that carries the OIDC issuer URL, the client ID
  (`storefront-web`), the redirect-URI allow-list, the PKCE flag.
- `admin-portal-spa-config.yaml` — the equivalent for the
  `admin-portal` client.

Phase 13b does not ship the storefront / admin SPA source (the v1
storefront at `../../../bookstore/app/storefront/` is the starting
point; Phase 13c wires the v2 variant via Backstage scaffolder). This
README stands as the placeholder so the directory exists in the tree.

## Cross-references

- Ch.13.04 — the chapter that wires real auth.
- `../../auth/` — the platform-level auth tree.
- `../../../bookstore/app/storefront/` — the v1 storefront the v2 SPA
  configuration parametrises.
