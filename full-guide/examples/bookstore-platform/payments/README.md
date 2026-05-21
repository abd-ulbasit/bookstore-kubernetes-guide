# `payments/` — Outbox publisher + payments-worker + Stripe webhook receiver

The v2 payments story (ch.13.06). Outbox pattern + Kafka + Stripe sandbox +
saga compensation. v1 used dequeue-once-from-RabbitMQ; v2 uses durable Kafka
+ idempotent processing + signed webhooks.

## Files

- `outbox-ddl.sql` — the `outbox` table schema. Applied either by a CNPG
  migration job or by the BookstoreTenant Composition (ch.13.02) when
  stamping a per-tenant logical DB.
- `outbox-publisher.yaml` — Deployment (3 replicas) that reads
  `outbox WHERE published_at IS NULL`, publishes to Kafka `orders.placed`,
  marks the row published. Uses Postgres advisory locks for single-active
  publisher per topic.
- `payments-worker.yaml` — Deployment (3 replicas) that consumes
  `orders.placed`, calls `payments-gateway` (which holds the Stripe key),
  writes the result, publishes `payments.completed`.
- `payments-webhook-receiver.yaml` — public-path Deployment + Service +
  Secret that receives Stripe webhook callbacks, verifies the
  Stripe-Signature header, and publishes the decoded events to Kafka
  (`payments.completed` on success; `payments.failed` on failure).
- `payments-webhook-authz.yaml` — the Istio `AuthorizationPolicy` that
  permits the public webhook path (kept separate so the receiver manifest
  dry-runs cleanly without Istio installed).
- `stripe-eso-externalsecret.yaml` — ESO `ExternalSecret` CRs that pull
  the Stripe API key + webhook secret from Vault.

## Apply order

```sh
# 1. The schema (one-shot via psql or by re-running CNPG migration job)
psql "$DB_DSN" -f examples/bookstore-platform/payments/outbox-ddl.sql

# 2. The two consumers + the receiver
kubectl apply -f examples/bookstore-platform/payments/outbox-publisher.yaml
kubectl apply -f examples/bookstore-platform/payments/payments-worker.yaml
kubectl apply -f examples/bookstore-platform/payments/payments-webhook-receiver.yaml

# 3. The Istio AuthorizationPolicy (after Istio is installed; ch.13.04)
kubectl apply -f examples/bookstore-platform/payments/payments-webhook-authz.yaml

# 4. (production) ESO pulls real Stripe keys from Vault
kubectl apply -f examples/bookstore-platform/payments/stripe-eso-externalsecret.yaml

# 5. Confirm
kubectl -n bookstore-platform-payments get deploy,svc,authorizationpolicy
```

## Honest note about Stripe on kind

The `payments-gateway` binary in `../app/payments-gateway/` uses the
official `github.com/stripe/stripe-go/v76` SDK. Real API calls need a
real Stripe sandbox account + a `sk_test_...` key. For pure-kind runs
the chapter walks the **mock Stripe** alternative:

```sh
# Run stripe-mock locally (pinned tag):
docker run -p 12111:12111 -p 12112:12112 stripe/stripe-mock:0.184.0
# Point payments-gateway at it:
export STRIPE_KEY="sk_test_fake"
export STRIPE_API_BASE="http://stripe-mock:12111"
```

The chapter calls this out explicitly; the manifests support both paths
via the `STRIPE_API_BASE` env var.

## Cross-references

- Ch.13.06 — the chapter that authors this stack.
- `../kafka/` — provides `orders.placed` + `payments.completed`.
- `../app/payments-gateway/` — the Stripe SDK + idempotency-key handling.
- `../app/events/` — the outbox publisher + payments-worker binary
  (one image, two `EVENTS_MODE` selectors).
- Part 11 ch.05 — ESO + Vault wiring (the production-shape Stripe key
  store).
