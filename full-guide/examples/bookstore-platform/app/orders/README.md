# `app/orders/` — Bookstore Platform orders service (stub)

## What this is

A minimal Go HTTP service that represents the orders domain of the
Bookstore Platform. It exposes three endpoints:

- `GET /healthz` — liveness probe; returns `{"status":"ok"}`.
- `GET /` — service identity; lists available endpoints.
- `POST /orders` — accepts a JSON body and echoes it back with a stub
  `order_id` and `"status":"accepted"`.

The binary uses only the Go standard library (`log/slog`, `net/http`,
`io`, `os/signal`) and shuts down gracefully on SIGTERM within 10 seconds.

## Why it's a stub

Parts 13, 14, and 15 of the guide reference an `orders` service as one
of the core Bookstore Platform microservices (alongside `catalog`,
`payments-gateway`, `payments-worker`, `search`, and `events`). The
service was introduced conceptually in Part 09 and its surrounding
Kubernetes manifests appear in several chapter examples (HPA targets,
NetworkPolicy egress rules, PodDisruptionBudgets, Argo Rollout canary
examples).

This stub exists so those cross-chapter references resolve to real,
buildable Go code and valid Kubernetes YAML rather than placeholders.
The chapter text focuses on traffic management and reliability — not
order business logic — so a simple echo is sufficient for every example
in the guide.

## What production would add

- PostgreSQL persistence with an outbox table for reliable event
  publishing (transactional outbox pattern, ch.13.05).
- Kafka publishing of `order.created` events consumed by
  `payments-worker`.
- Order state machine: `pending` -> `confirmed` -> `shipped` -> `delivered`.
- `GET /orders/{id}` and `GET /orders` (paginated) endpoints.
- OpenTelemetry tracing and Prometheus metrics.
- gRPC alongside HTTP/JSON for internal service-to-service calls.
- Input validation, duplicate detection via idempotency keys.

## Build and run locally

```sh
cd examples/bookstore-platform/app/orders

# Vet and build
make test

# Run locally (listens on :8080)
go run .

# In a second terminal — create a stub order
curl -s -X POST http://localhost:8080/orders \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"cust-1","book_id":"1","quantity":2}' | jq .
# {
#   "book_id": "1",
#   "customer_id": "cust-1",
#   "order_id": "ord-stub-001",
#   "quantity": 2,
#   "status": "accepted"
# }

# Healthcheck
curl http://localhost:8080/healthz
# {"status":"ok"}

# Build container image (requires Docker)
make image
```

## Cross-references

- Parts 13/14/15 — chapters that reference this service in HPA, VPA,
  PodDisruptionBudget, NetworkPolicy, and GitOps pipeline examples.
- `../catalog/` — the catalog stub; production orders would validate
  book IDs and prices against catalog.
- `../payments-gateway/` — receives charge requests after orders are
  confirmed.
- `../payments-worker/` — polls for confirmed orders and initiates
  payment processing.
