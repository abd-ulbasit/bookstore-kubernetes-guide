# `app/` — Bookstore Platform v2 service source

Phase 13b adds five service skeletons under this directory; Phase 13a
shipped only this README pointing forward. Each service is small (~150-200
lines of Go), builds clean (`go vet` + `go build` + `docker build` all
exit 0), and demonstrates ONE production-shape pattern.

## The v2 services in this tree

| Service | What it is | Chapter |
|---------|------------|---------|
| `search/` | Per-tenant Meilisearch wrapper. Reads `x-jwt-payload` for the tenant claim, queries `books-<TENANT>` in Meilisearch. | 13.05 |
| `payments-gateway/` | Stripe SDK wrapper. One binary, two PAYMENTS_MODE-selected paths: `/charge` (Stripe PaymentIntents with idempotency-key) and `/stripe/webhook` (Stripe-Signature verifier). | 13.06 |
| `events/` | Kafka dispatcher. One binary, three EVENTS_MODE-selected paths: outbox publisher, payments-worker, drift-relay. | 13.06 / 13.08 |
| `recommendations/` | KServe predictor wrapper. POSTs to the InferenceService, publishes each prediction to `ml.predictions` for drift detection. | 13.08 |
| `auth/` | Stub. SPA OIDC config that points at the Keycloak realm. The real auth wiring is at `../../auth/`. | 13.04 |

## The v1 services they extend

The v1 storefront / catalog / orders / payments-worker source lives at
[`../../bookstore/app/`](../../bookstore/app/README.md) and stays unchanged
under Phase 13's additive-only discipline. The v2 services contrast with
v1 as follows:

| Capability | v1 service | v2 service |
|------------|-----------|-----------|
| Search | catalog's `SELECT ... LIKE` | `search/` -> Meilisearch |
| Payments | `payments-worker` consuming RabbitMQ | `payments-gateway/` + `events/` consuming Kafka |
| Events | RabbitMQ ephemeral queue | `events/` consuming Kafka topics |
| Recommendations | rule-based hand-written | `recommendations/` -> KServe + MLflow |
| Auth (humans) | catalog + orders trust a shared HMAC | `../../auth/` Keycloak + Istio JWT verify (ch.13.04) |

## Build all five

```sh
for svc in search payments-gateway events recommendations; do
  ( cd examples/bookstore-platform/app/$svc \
    && go vet ./... \
    && go build ./... \
    && docker build -t bookstore-platform/$svc:dev . )
done
```

## Cross-references

- Ch.13.05 / 13.06 / 13.07 / 13.08 — the four chapters that introduce
  these services.
- `../../bookstore/app/` — the v1 services these extend.
- `../auth/` / `../search/` / `../payments/` / `../edge/` / `../ml/` /
  `../kafka/` — the platform-level manifests that surround these
  services.
