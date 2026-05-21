# `app/recommendations/` — v2 recommendations API (KServe wrapper)

A small Go service introduced in ch.13.08. POSTs to the KServe predictor
(which serves the model from MLflow); publishes each prediction to Kafka
`ml.predictions` for the drift detector.

## What it does

1. Reads the verified `x-jwt-payload` header (Istio sets it post JWT
   verification; ch.13.04) and extracts the `tenant` claim.
2. POSTs the request body to the KServe v1 protocol endpoint
   `/v1/models/recommender:predict`.
3. Returns the predictions to the caller.
4. Async-publishes the prediction event to Kafka `ml.predictions` for
   Alibi-Detect to consume.

## What it does not do (out of scope)

- Embedding cache for hot users.
- Request batching to amortise KServe RPCs.
- A/B test traffic split via feature-flag SDK.
- Streaming response (predictions can be large).

The chapter calls these out; this is a 150-line demonstration.

## Build + run

```sh
cd examples/bookstore-platform/app/recommendations
go vet ./...
go build ./...
docker build -t bookstore-platform/recommendations:dev .
```

## Cross-references

- Ch.13.08 — the chapter that introduces this service.
- `../../ml/inferenceservice.yaml` — the KServe predictor this service
  calls.
- `../../ml/alibi-detect-drift.yaml` — the drift detector that consumes
  `ml.predictions`.
- `../../kafka/topics.yaml` — `ml.predictions` is implicit (the topic is
  created on first write; production should add it to topics.yaml).
