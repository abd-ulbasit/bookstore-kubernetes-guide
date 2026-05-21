# `app/search/` — v2 search API (per-tenant Meilisearch wrapper)

A small Go service introduced in ch.13.05. Reads the verified
`x-jwt-payload` header that the Istio gateway injects (ch.13.04), extracts
the `tenant` claim, queries the per-tenant Meilisearch index
(`books-<TENANT>`), returns the engine's JSON response.

## Why so small

The service is a 150-line wrapper that demonstrates two patterns:

1. **Per-tenant routing from a JWT claim** — the same pattern every v2
   service applies (recommendations, payments-gateway). One place to
   teach it.
2. **Trusting the gateway-verified JWT** — downstream services do NOT
   re-validate the JWT; they trust the `x-jwt-payload` header the
   gateway wrote. The mesh's mTLS is the trust boundary (ch.13.04).

A full search service would add ranking customisation, faceted filters,
query autocomplete, click-through tracking, etc. — out of scope for the
chapter.

## Build + run locally

```sh
cd examples/bookstore-platform/app/search
go vet ./...
go build ./...
docker build -t bookstore-platform/search:dev .
```

## Try it

```sh
# 1. Stand up Meilisearch (cross-ref ../../search/README.md)
# 2. Index some books in `books-acme-books` index
# 3. Load it into kind
kind load docker-image bookstore-platform/search:dev --name bookstore-platform-us-east

# 4. Apply
kubectl apply -f examples/bookstore-platform/app/search/deployment.yaml
kubectl apply -f examples/bookstore-platform/app/search/service.yaml

# 5. With a JWT from ch.13.04
curl -sk -H "Authorization: Bearer $JWT" \
  https://localhost:8443/api/v2/search?q=kubernetes
```

## Cross-references

- Ch.13.05 — the chapter that introduces this service.
- `../../search/meilisearch.yaml` — the search engine.
- `../../auth/` (ch.13.04) — the JWT verification that writes
  `x-jwt-payload`.
