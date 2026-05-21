# `search/` — Meilisearch + Debezium CDC

The v2 search story (ch.13.05). Postgres -> Debezium -> Kafka -> Meilisearch.
Per-tenant index isolation. Regional (one Meilisearch per region; no cross-
region replication — each region's CDC feeds its local engine).

## Files

- `meilisearch.yaml` — StatefulSet + headless Service + PVC + non-root
  PodSpec (restricted-PSA-compatible) + a placeholder master-key Secret
  (REPLACE via ESO + Vault).
- `debezium-connector.yaml` — Strimzi `KafkaConnect` cluster (1 worker;
  Debezium plugin + Camel HTTP sink baked in via Strimzi build) +
  two `KafkaConnector` instances: Postgres -> `books.cdc` source and
  `books.cdc` -> Meilisearch sink.

## Apply order

```sh
# 1. Strimzi + Kafka cluster + topics (cross-ref ../kafka/README.md)
kubectl apply -f examples/bookstore-platform/kafka/cluster.yaml
kubectl apply -f examples/bookstore-platform/kafka/topics.yaml

# 2. Meilisearch
kubectl apply -f examples/bookstore-platform/search/meilisearch.yaml

# 3. Debezium Postgres + sink (after CNPG has wal_level=logical)
kubectl apply -f examples/bookstore-platform/search/debezium-connector.yaml

# 4. Confirm
kubectl -n bookstore-platform-search get statefulset,svc
kubectl -n kafka-system get kafkaconnect,kafkaconnector
```

## How the per-tenant index name shows up

Each row in the source `books` table has a `tenant_id` column. The
chapter walks two SMT options:

1. Route at the source: a Debezium routing SMT rewrites the topic to
   `books.cdc.<TENANT_ID>` and a per-tenant sink connector exists.
   Simple; one sink per tenant; works at low N.
2. Route at the sink: one topic, one sink, the Camel HTTP sink's URL
   template substitutes `<TENANT_ID>` into the Meilisearch endpoint
   `/indexes/books-<TENANT_ID>/documents`. Better at high N.

Phase 13b ships option (2); the chapter calls out when to switch.

## Cross-references

- Ch.13.05 — the chapter that introduces this stack.
- `../kafka/` — the event bus that carries `books.cdc`.
- `../crossplane/composition-bookstoretenant.yaml` (ch.13.02) — the
  Composition stamps a per-tenant logical DB whose `books` table feeds
  this pipeline.
- Ch.13.06 — uses the SAME Kafka cluster for `orders.placed` +
  `payments.completed`; the chapter explicitly avoids "two Kafkas".
