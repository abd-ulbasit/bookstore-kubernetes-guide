# `app/payments-gateway/` — v2 payments gateway (Stripe SDK + webhook)

A small Go service introduced in ch.13.06. One binary, two modes:

- `PAYMENTS_MODE=gateway` — POST `/charge` calls Stripe PaymentIntents
  with an idempotency key derived from the order's `event_id`.
- `PAYMENTS_MODE=webhook-receiver` — POST `/stripe/webhook` verifies the
  Stripe-Signature header and publishes `payments.completed` to Kafka.

## Why one binary for two roles

The two roles share initialisation: the Stripe SDK, the JSON encoder
defaults, the metrics, the health probes. Splitting them in two binaries
duplicates that — and means a Stripe SDK upgrade requires updating two
services. One binary, two `PAYMENTS_MODE`-selected paths is the minimum-
maintenance shape; the chapter's "Production notes" calls out the trade.

## Stripe key handling

The `STRIPE_KEY` env var is set from a Kubernetes Secret named
`stripe-api-key`. In production that Secret is materialised by ESO from
Vault (`../../payments/stripe-eso-externalsecret.yaml`); on kind the
Secret in `deployment.yaml` is a labelled placeholder.

For kind without a real Stripe sandbox account, set
`STRIPE_API_BASE=http://stripe-mock.bookstore-platform-payments.svc.cluster.local:12111`
and run a `stripe/stripe-mock` Pod next to this Deployment. The chapter
walks both paths.

## Webhook signature verification

The `webhook.ConstructEvent` call from `stripe-go/v76` validates the
HMAC + timestamp in the `Stripe-Signature` header. An attacker without
the webhook secret cannot forge a valid header for a body they choose;
the chapter's "Production notes" calls out this as the trust boundary
and warns against ever skipping it.

## Build + run

```sh
cd examples/bookstore-platform/app/payments-gateway
go vet ./...
go build ./...
docker build -t bookstore-platform/payments-gateway:dev .
```

## Cross-references

- Ch.13.06 — the chapter that introduces this service.
- `../../payments/` — the surrounding deployment manifests
  (outbox-publisher, payments-worker, payments-webhook-receiver).
- `../events/` — the dispatcher that consumes Kafka topics and POSTs to
  this gateway's `/charge` endpoint.
