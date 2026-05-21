# `kafka/` — Strimzi Kafka cluster + topics

Ch.13.05 introduces the event bus the rest of Phase 13b rides on. Strimzi
is the Kubernetes operator for Kafka; KRaft mode (no ZooKeeper) is the
default on the 3.7.0 broker the cluster pins.

## Files

- `cluster.yaml` — the `Kafka` CR (KRaft mode, listeners + cluster-level
  config). With `strimzi.io/node-pools: enabled`, broker count + storage
  + resources are owned by the `KafkaNodePool`, not this file.
- `nodepool.yaml` — the `KafkaNodePool` CR that declares 3 combined
  (broker + controller) KRaft nodes with per-broker persistent-claim
  storage and a restricted-PSA-compatible Pod template.
- `topics.yaml` — six KafkaTopic CRs that the Topic Operator reconciles
  into real Kafka topics:
  - `books.cdc` — Debezium Postgres CDC stream (ch.13.05).
  - `orders.placed` — outbox-published order events (ch.13.06).
  - `payments.completed` — Stripe webhook completions (ch.13.06).
  - `payments.failed` — saga-compensation events (ch.13.06).
  - `ml.predictions` — recommender prediction stream (ch.13.08).
  - `ml.drift` — Alibi-Detect drift events (ch.13.08).

## Apply order

```sh
# 1. Install Strimzi operator (pinned-Helm; cross-ref ch.13.05 Hands-on §1)
STRIMZI_VERSION="0.40.0"
helm repo add strimzi https://strimzi.io/charts/
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --version "$STRIMZI_VERSION" -n kafka-system --create-namespace --wait

# 2. Apply the cluster CR THEN the node pool (Strimzi requires the cluster
#    to exist before the pool can reference it; both reach Ready together).
kubectl apply -f examples/bookstore-platform/kafka/cluster.yaml
kubectl apply -f examples/bookstore-platform/kafka/nodepool.yaml

# 3. Apply the topics (after the cluster is Ready ~2 min on kind)
kubectl apply -f examples/bookstore-platform/kafka/topics.yaml

# 4. Confirm
kubectl -n kafka-system get kafka,kafkanodepool,kafkatopic
```

## Cross-references

- Ch.13.05 — uses `books.cdc` for Debezium Postgres -> Meilisearch.
- Ch.13.06 — uses `orders.placed` + `payments.completed` for the outbox
  + saga compensation.
- Ch.13.08 — uses `ml.drift` for Alibi-Detect -> Argo Events retrain.
- Ch.13.09 (Phase 13c) — wires per-topic Kafka metrics into Prometheus.

## Why a separate Kafka cluster per region

The chapter argues for region-local topics (each region's writers feed
the local Kafka; cross-region replay uses MirrorMaker 2, not direct cross-
region producers). The Phase 13b chapter installs one cluster per region;
MirrorMaker 2 lands in ch.13.12 as a day-2 follow-up. The 3-broker
footprint per region is the smallest production-shape that survives one
broker loss without data loss.
