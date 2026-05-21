# `app/payments-worker/` — Bookstore Platform payments-worker (stub)

## What this is

A minimal Go background-worker service that represents the payments
processing worker in the Bookstore Platform. It runs two concurrent
paths:

- A **polling loop** that ticks every 30 seconds and logs
  `"polling for orders..."`. In production this polls the outbox table
  or consumes from the `order.created` Kafka topic.
- A **health HTTP server** on `:8080` that exposes `GET /healthz`
  (returns `{"status":"ok"}`) so Kubernetes liveness probes work.

The binary uses only the Go standard library (`log/slog`, `net/http`,
`time`, `os/signal`) and shuts down gracefully on SIGTERM within 10
seconds.

## Why it's a stub

Parts 13, 14, and 15 of the guide reference a `payments-worker` service
as one of the background components in the Bookstore Platform (alongside
`payments-gateway`, `catalog`, `orders`, and `events`). The service
appears in surrounding deployment manifests, Kafka consumer group
examples, and the transactional outbox pattern discussion in ch.13.05.

This stub exists so those cross-chapter references resolve to real,
buildable Go code and a valid Kubernetes Deployment manifest rather than
placeholders. No `service.yaml` is needed — this worker has no
inbound traffic.

## What production would add

- Kafka consumer (via `segmentio/kafka-go`) on the `order.created`
  topic, replacing the ticker-based polling loop.
- Transactional outbox polling as a fallback if Kafka is unavailable
  (ch.13.05 pattern).
- HTTP call to `payments-gateway POST /charge` with the order payload
  and an idempotency key derived from the order's `event_id`.
- Dead-letter queue (DLQ) publishing for orders that fail after N
  retries.
- OpenTelemetry tracing (span from Kafka message to gateway response).
- Prometheus metrics: `payments_worker_orders_processed_total`,
  `payments_worker_poll_duration_seconds`.

## Build and run locally

```sh
cd examples/bookstore-platform/app/payments-worker

# Vet and build
make test

# Run locally — starts polling loop + health server on :8080
go run .
# time=... level=INFO msg="payments-worker health endpoint listening" addr=:8080
# time=... level=INFO msg="payments-worker started" poll_interval=30s
# time=... level=INFO msg="polling for orders..."   (every 30s)

# In a second terminal
curl http://localhost:8080/healthz
# {"status":"ok"}

# Build container image (requires Docker)
make image
```

## Cross-references

- Parts 13/14/15 — chapters that reference this worker in Kafka consumer
  group examples, transactional outbox pattern, and payment flow diagrams.
- `../payments-gateway/` — the gateway this worker calls after
  dequeuing an order event.
- `../orders/` — the service that emits `order.created` events consumed
  by this worker.
