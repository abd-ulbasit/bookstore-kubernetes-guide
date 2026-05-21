# `app/events/` — Kafka dispatcher (outbox, payments-worker, drift-relay)

A small Go service introduced in ch.13.06. One binary, three
EVENTS_MODE-selected paths:

- `outbox` — read Postgres `outbox` WHERE published_at IS NULL, publish
  each row to Kafka `orders.placed`, mark published.
- `payments-worker` — consume `orders.placed`, POST to payments-gateway
  `/charge`, on success publish `payments.completed`, commit offset.
- `drift-relay` — consume `ml.drift`, log each event (used by ch.13.08
  as a smoke test).

## Why one binary

Same logic as `app/payments-gateway`: shared init (Kafka client, health
server, metrics) factored once. Dependency upgrades affect one image.

## Build + run

```sh
cd examples/bookstore-platform/app/events
go vet ./...
go build ./...
docker build -t bookstore-platform/events:dev .
```

## Deployments

- `../../payments/outbox-publisher.yaml` — runs this image with
  `EVENTS_MODE=outbox`.
- `../../payments/payments-worker.yaml` — runs this image with
  `EVENTS_MODE=payments-worker`.
- `./deployment.yaml` (this dir) — runs `EVENTS_MODE=drift-relay` for
  ch.13.08's smoke test.

## Cross-references

- Ch.13.06 — outbox + payments-worker.
- Ch.13.08 — drift-relay.
- `../../kafka/` — the topics this dispatcher reads + writes.
- `../payments-gateway/` — the Stripe-SDK service the payments-worker
  mode calls.
