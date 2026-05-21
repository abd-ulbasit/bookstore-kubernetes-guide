# `app/catalog/` — Bookstore Platform catalog service (stub)

## What this is

A minimal Go HTTP service that represents the catalog domain of the
Bookstore Platform. It exposes two endpoints:

- `GET /healthz` — liveness probe; returns `{"status":"ok"}`.
- `GET /` — returns a hardcoded JSON list of three sample books plus a
  `"service":"catalog"` identity field.

The binary uses only the Go standard library (`log/slog`, `net/http`,
`os/signal`) and shuts down gracefully on SIGTERM within 10 seconds.

## Why it's a stub

Parts 13, 14, and 15 of the guide reference a `catalog` service as one
of the core Bookstore Platform microservices (alongside `orders`,
`payments-gateway`, `payments-worker`, `search`, and `events`). The
service was introduced conceptually in Part 09 and its surrounding
Kubernetes manifests appear in several chapter examples.

This stub exists so those cross-chapter references resolve to real,
buildable Go code and valid Kubernetes YAML rather than placeholders.
The chapter text focuses on observability, GitOps, and traffic
management — not catalog business logic — so a hardcoded response is
sufficient for every example in the guide.

## What production would add

- PostgreSQL integration (book records, ISBN uniqueness, full-text search
  via tsvector) or an Elasticsearch/Meilisearch backend for fuzzy search.
- Pagination (`limit` / `offset` or cursor-based) on `GET /`.
- `GET /books/{id}` and `POST /books` (admin-only) endpoints.
- OpenTelemetry tracing with the `go.opentelemetry.io/otel` SDK.
- Prometheus metrics via `prometheus/client_golang`.
- Real readiness probe that pings the DB before reporting ready.
- gRPC alongside HTTP/JSON for internal service-to-service calls.

## Build and run locally

```sh
cd examples/bookstore-platform/app/catalog

# Vet and build
make test

# Run locally (listens on :8080)
go run .

# In a second terminal
curl http://localhost:8080/healthz
# {"status":"ok"}

curl http://localhost:8080/
# {"books":[...],"service":"catalog"}

# Build container image (requires Docker)
make image
```

## Cross-references

- Parts 13/14/15 — chapters that reference this service in NetworkPolicy,
  HPA, VPA, PodDisruptionBudget, and GitOps pipeline examples.
- `../orders/` — the orders stub that this service would call to validate
  stock before confirming an order in production.
- `../payments-gateway/` — the payment service that processes charges
  after orders reference catalog prices.
