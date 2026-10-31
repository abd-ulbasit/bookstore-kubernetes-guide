# `payments/`: Outbox publisher, payments-worker and Stripe webhook receiver

The v2 payments story (ch.13.06). Outbox pattern, Kafka over TLS with one
identity and ACL set per workload, Stripe sandbox, and signed webhooks. v1
used dequeue-once-from-RabbitMQ; v2 uses durable Kafka, idempotent processing
and verified webhooks.

## Files

- `outbox-ddl.sql`: the `outbox` table, the `payments` replay table and the
  per-role grants. Applied either by a CNPG migration job or by the
  BookstoreTenant Composition (ch.13.02) when stamping a per-tenant database.
- `outbox-publisher.yaml`: Deployment (3 replicas) that claims unpublished
  outbox rows with `FOR UPDATE SKIP LOCKED`, publishes them to Kafka
  `orders.placed`, and marks them published.
- `payments-worker.yaml`: Deployment (3 replicas) that consumes
  `orders.placed`, has `payments-gateway` charge once, records the payment
  intent in `payments`, and publishes the outcome to `payments.completed` or
  `payments.failed`.
- `payments-webhook-receiver.yaml`: public-path Deployment and Service that
  verifies the Stripe-Signature header and publishes the decoded events.
- `payments-webhook-authz.yaml`: the Istio `AuthorizationPolicy` that admits
  the public webhook path (kept separate so the receiver manifest dry-runs
  cleanly without Istio installed).
- `kafka-users.yaml`: one Strimzi `KafkaUser` per workload, with simple ACLs
  on the topics it uses, and the Role that lets the ESO reader copy the three
  user secrets into this namespace.
- `stripe-eso-externalsecret.yaml`: the ExternalSecrets for every credential
  of the path: the Stripe key and webhook secret, the two database DSNs and
  the Kafka client certificates.
- `stripe-mock.yaml`: stripe-mock, for the kind sandbox only.

## Apply order

```sh
# 1. The schema, as the outbox role's owner (one-shot via psql, or by re-running
#    the CNPG migration job)
psql "$DB_DSN" -f examples/bookstore-platform/payments/outbox-ddl.sql

# 2. The secrets, the Kafka identities and the stripe-mock sandbox
kubectl apply -f examples/bookstore-platform/payments/stripe-eso-externalsecret.yaml
kubectl apply -f examples/bookstore-platform/payments/kafka-users.yaml
kubectl apply -f examples/bookstore-platform/payments/stripe-mock.yaml

# 3. The two consumers, the receiver and the gateway
kubectl apply -f examples/bookstore-platform/payments/outbox-publisher.yaml
kubectl apply -f examples/bookstore-platform/payments/payments-worker.yaml
kubectl apply -f examples/bookstore-platform/payments/payments-webhook-receiver.yaml
kubectl apply -f examples/bookstore-platform/app/payments-gateway/deployment.yaml
kubectl apply -f examples/bookstore-platform/app/payments-gateway/service.yaml

# 4. The Istio AuthorizationPolicy (after Istio is installed; ch.13.04)
kubectl apply -f examples/bookstore-platform/payments/payments-webhook-authz.yaml

# 5. Confirm
kubectl -n bookstore-platform-payments get deploy,svc,externalsecret
```

## Honest note about Stripe on kind

The `payments-gateway` binary in `../app/payments-gateway/` uses the official
`github.com/stripe/stripe-go/v76` SDK. Real API calls need a Stripe sandbox
account and a `sk_test_...` key. Without one, run `stripe-mock.yaml` and point
the gateway at it with `STRIPE_API_BASE`:

```sh
kubectl -n bookstore-platform-payments set env deployment/payments-gateway \
  STRIPE_API_BASE="http://stripe-mock:12111"
```

stripe-mock wants a key shaped like a test key (`sk_test_` followed by letters
and digits) and needs no real secret. Never set `STRIPE_API_BASE` in production.

## Cross-references

- Ch.13.06: the chapter that authors this stack.
- `../kafka/`: provides `orders.placed`, `payments.completed` and
  `payments.failed`, and the TLS listener these clients use.
- `../app/payments-gateway/`: the Stripe SDK and the Idempotency-Key handling.
- `../app/events/`: the outbox publisher and the payments-worker (one image,
  two `EVENTS_MODE` selectors).
- Part 11 ch.05: ESO and Vault (the production-shape credential store).
