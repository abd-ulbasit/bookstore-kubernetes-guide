# 13.05 — Search and product discovery

> Meilisearch on Kubernetes, Postgres -> search index via Debezium CDC,
> per-tenant index isolation.

**Estimated time:** ~45 min read · half-day hands-on
**Prerequisites:** [Part 03 ch.05](../03-config-and-storage/05-stateful-data-patterns.md) — stateful patterns Meilisearch and Kafka rely on · [Part 13 ch.02](02-tenancy-and-crossplane-onboarding.md) — tenant boundary search must respect · [Part 13 ch.06](06-payments-and-event-sourcing.md) — Kafka/Strimzi infra Debezium publishes to
**You'll know after this:** • install Meilisearch on Kubernetes with PVC + auth + restricted PSA · • stand up Debezium against Postgres for change-data-capture · • design per-tenant index isolation (index-per-tenant vs filter-by-tenant) · • wire CDC events through Kafka into the search index in near-real-time · • plan reindexing + schema-evolution without downtime

<!-- tags: bookstore-v2, stateful, meilisearch, debezium, kafka, multi-tenancy -->

## Why this exists

The v1 Bookstore's `catalog` service answered "show me books" with
`SELECT id, title, author, price FROM books ORDER BY id`. That works for
four books at the top of [`bookstore/app/catalog/main.go`](../examples/bookstore/app/catalog/main.go).
It fails for the **real** e-commerce shape along five specific axes:

1. **No relevance ranking.** A `LIKE '%kubernetes%'` query against a
   million-row `books` table returns every match in primary-key order. A
   customer typing `kubernetes` wants the **best** match first, not the
   oldest-rowid match.
2. **No typo tolerance.** A customer types `kuberentes` (transposed `e`
   and `n`); the SQL `LIKE` returns zero rows. Real search engines match
   typos within a configurable edit distance.
3. **No filters or facets.** "Books with price under $30 by Marko Lukša"
   needs `WHERE price < 30 AND author = ?` plus a per-facet aggregate
   (count of books in each price bucket); SQL can do it but it's slow
   and you build the facet UI by hand.
4. **No autocomplete.** "Type-as-you-search" needs a sub-50 ms partial-
   match query; SQL `LIKE 'kuber%'` over a million rows is 500 ms+ even
   with a trigram index.
5. **The search workload poisons the OLTP path.** A heavy search query
   hits the same Postgres connections that orders + payments depend on;
   one bad query and checkout latency triples. Search needs its own
   data plane.

v2 ships a real search engine. The architecture is two pieces — an
**index** (Meilisearch, OpenSearch, Typesense, or Algolia) and a **way
to keep it in sync with Postgres** (Debezium CDC -> Kafka -> sink) —
each chosen with the operational shape of a Kubernetes e-commerce
platform in mind.

> **In production:** Teams hesitate to adopt a search engine because
> "Postgres full-text search is fine for now." It is — until the day it
> is not, and then you ship a search engine **under traffic** instead of
> **before** traffic. v2's discipline is to ship the search engine
> alongside the catalog before the LIKE query ever became a problem;
> the cost of the engine + CDC pipeline is multi-engineer days, the
> cost of ripping out LIKE at scale is multi-engineer weeks.

## Mental model

**Search = (an index) + (a way to keep it in sync). The index lives next
to your workloads; the sync uses change-data-capture; per-tenant
isolation is a per-tenant index name; cross-region is per-region
indexes fed by the local CDC pipeline.**

- **The index — Meilisearch.** Four candidates real teams pick from on
  Kubernetes:
  - **Meilisearch** — single Go binary, single process, low memory,
    typo-tolerant + relevant out of the box. The easiest operational
    story; one StatefulSet, one PVC.
  - **OpenSearch / Elasticsearch** — JVM, sharded, mature, vast
    ecosystem. The right pick for >100M documents, complex aggregations,
    full Elastic query DSL.
  - **Typesense** — C++, fast, simple. Smaller community than the
    others; comparable operational profile to Meilisearch.
  - **Algolia** — SaaS. Zero ops; per-search cost. The right pick if
    your team has no ops capacity and the search cost fits the unit
    economics.
  The platform v2 picks Meilisearch because the e-commerce shape (1M-10M
  books per tenant; typo tolerance + faceting + relevance the customer
  notices; one binary on K8s) is exactly where it shines. The chapter's
  comparison table walks the trade.
- **The sync — Debezium CDC, not application dual-writes.** Three ways
  to keep an index synchronized with a database:
  - **Application dual-write** — application writes to Postgres AND
    Meilisearch in one transaction. Simple; broken — there is no
    cross-system transaction, so a half-failed write leaves them out of
    sync. **Reject this pattern.**
  - **Application-emit-event** — application writes to Postgres + emits
    a Kafka event; a consumer applies the event to Meilisearch. Works
    but couples the application to the indexing path.
  - **Change-data-capture (Debezium)** — Postgres's write-ahead log
    (WAL) is the event stream; Debezium reads it and produces a Kafka
    topic. The application code does not change; the WAL is the source
    of truth. **This is what v2 ships.**
- **Per-tenant indexing — one index per tenant.** Each tenant gets
  `books-<TENANT_ID>` (e.g. `books-acme-books`, `books-contoso-books`).
  The sink connector reads each row's `tenant_id` column and writes to
  the matching index. Cross-tenant search is then **impossible by
  construction** — querying `books-acme-books` cannot return a
  contoso-books document because they live in different indexes.
- **Cross-region — same topology, per region.** Each region runs its
  own Meilisearch + Debezium + Kafka. CNPG's per-region replica is the
  Debezium source in that region (logical replication slot on the
  primary; the replica forwards the WAL stream). Search is **regional**;
  cross-region search consistency is eventual and bounded by the WAL
  replication lag. Sell the truth.

The trap to keep in view: **CDC is at-least-once.** Meilisearch writes
must be **idempotent** — the same Kafka message arriving twice writes
the same document version, not a duplicate. The sink uses the document's
primary key (the `books.id` column); Meilisearch upserts by primary key
deterministically.

## Threats and controls

The search path adds four attack surfaces to the platform: a listener that
takes writes from any pod, a key that can do more than search, a plugin
archive nobody checked, and a password written into a manifest.

| Threat | Control taught here | Deeper |
|---|---|---|
| A pod that is not a Kafka client writes or reads `books.cdc` | One TLS listener with mutual TLS, `authorization: simple`, and a KafkaUser whose ACLs name only the topics it uses (steps 2 and 5) | [Part 11 ch.04](../11-advanced-production-patterns/04-service-mesh.md) for the mesh |
| A key that can delete indexes or list keys ends up in a workload | Scoped Meilisearch keys: `documents.add` for the sink, `search` for the service, both on `books-*` and both expiring (step 4) | [Meilisearch API keys](https://www.meilisearch.com/docs/learn/security/master_api_keys) |
| A plugin archive is swapped between review and build | A `sha512sum` on each plugin artifact, verified by Strimzi at build (step 5) | [Strimzi 0.40.0 docs](https://strimzi.io/docs/operators/0.40.0/configuring.html) |
| A password or key is committed in a manifest or a connector spec | External Secrets fills each Secret; connectors read files with `${dir:...}` (steps 3, 5 and 7) | [Part 13 ch.06](06-payments-and-event-sourcing.md) |

## Diagrams

### Diagram A — CDC pipeline (Mermaid)

```mermaid
flowchart LR
    subgraph reg["region us-east"]
      app["catalog / orders<br/>writes books rows"]
      pg[("Postgres<br/>(CNPG primary)<br/>wal_level=logical")]
      dbz["Debezium<br/>KafkaConnect"]
      k[["Kafka<br/>topic: books.cdc"]]
      sink["Camel HTTP sink<br/>KafkaConnect"]
      mei[("Meilisearch<br/>books-acme-books<br/>books-contoso-books")]
      api["search service<br/>/v2/search?q=..."]
    end

    app -->|"INSERT / UPDATE / DELETE"| pg
    pg -.->|"logical replication<br/>slot: debezium_books"| dbz
    dbz -->|"per-row JSON<br/>key = books.id"| k
    k --> sink
    sink -->|"POST /indexes/books-acme-books/documents<br/>(tenant routed from row.tenant_id)"| mei
    api -->|"POST /indexes/books-acme-books/search"| mei

    note["At-least-once delivery<br/>Idempotent upsert on books.id<br/>SMT routes per-tenant"]
    k -.- note
```

### Diagram B — multi-region (Mermaid)

```mermaid
flowchart TB
    subgraph us["region us-east — writer"]
      us_pg[("CNPG primary")]
      us_dbz["Debezium"]
      us_k[["Kafka local"]]
      us_mei[("Meilisearch local")]
    end

    subgraph eu["region eu-west — reader"]
      eu_pg[("CNPG replica<br/>streaming")]
      eu_dbz["Debezium"]
      eu_k[["Kafka local"]]
      eu_mei[("Meilisearch local")]
    end

    subgraph ap["region ap-southeast — reader"]
      ap_pg[("CNPG replica<br/>streaming")]
      ap_dbz["Debezium"]
      ap_k[["Kafka local"]]
      ap_mei[("Meilisearch local")]
    end

    us_pg -.->|"streaming<br/>replication"| eu_pg
    us_pg -.->|"streaming<br/>replication"| ap_pg

    us_pg --> us_dbz --> us_k --> us_mei
    eu_pg --> eu_dbz --> eu_k --> eu_mei
    ap_pg --> ap_dbz --> ap_k --> ap_mei

    note["Each region indexes from its OWN<br/>Postgres replica. No cross-region<br/>search traffic. Lag bounded by<br/>CNPG replication."]
    us_mei -.- note
```

### Diagram C — search-engine-choice matrix (ASCII)

```text
DIMENSION              MEILISEARCH       OPENSEARCH         TYPESENSE         ALGOLIA
─────────────────────  ────────────────  ─────────────────  ────────────────  ─────────────────────
Language               Go                Java (JVM)         C++               SaaS (closed)
K8s topology           1 StatefulSet     N-shard cluster    1 StatefulSet     external (HTTPS)
Typo tolerance         built-in          configurable       built-in          built-in
Facets / filters       built-in          built-in           built-in          built-in
Multi-tenant pattern   index-per-tenant  index-per-tenant   collection-per-t  app-per-tenant
Cluster mode (HA)      upstream docs     yes (mature)       yes               managed
Cost                   self-hosted       self-hosted        self-hosted       per query
When it wins           <10M docs/t,      >100M docs, full   speed > breadth   zero ops capacity
                       low ops cost      Elastic features
```

The table leaves out memory and latency figures. This chapter did not measure
them, and they change with each release.

## Hands-on with the Bookstore Platform

Assumes the three regions from
[13.01](01-bookstore-2-from-toy-to-platform.md) are up and the platform-
base from 13.01 is applied. We work in `us-east`; the Argo CD
ApplicationSet (13.03) replicates this stack into `eu-west` and
`ap-southeast` automatically. Every workload manifest below carries the
[security baseline](../01-core-workloads/01-pods.md#baseline), and this
chapter explains only the fields that are new here. Namespaces:
`kafka-system` is labelled `baseline` (step 1); the others are `restricted`.

### 1. Install the Strimzi Kafka operator (pinned-Helm)

Phase 13b's three event-driven chapters (13.05, 13.06, 13.08) all use
Kafka. This chapter is the first to install it; 13.06 and 13.08 assume
it's there.

```sh
kubectl config use-context kind-bookstore-platform-us-east

# Label the namespace before the operator lands in it. kafka-system is
# baseline, not restricted: the Connect build runs as root (see below).
kubectl create namespace kafka-system
kubectl label namespace kafka-system \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest

STRIMZI_VERSION="0.40.0"

helm repo add strimzi https://strimzi.io/charts/
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --version "$STRIMZI_VERSION" -n kafka-system \
  -f examples/bookstore-platform/kafka/strimzi-values.yaml --wait
```

The values file sets the chart's own security fields. The operator image
declares UID 1001, so the pod runs as that user with no privilege
escalation, every capability dropped and a read-only root filesystem. The
chart mounts `/tmp` from an emptyDir, so the read-only root does not stop
the operator from starting.

**Why baseline.** The operator and the Kafka pods meet `restricted`. The
KafkaConnect build does not. Strimzi builds the Connect image with the
Kaniko executor, and that image declares no user and sets `USER=root`, so
the build runs as root. A namespace has one level, so `kafka-system` takes
`baseline`, the strictest level that admits the build. The exception is
registered in `security/namespace-exceptions.yaml` with its reason and an
expiry. `examples/bookstore-platform/kafka/networkpolicy.yaml` gives
`kafka-system` a default deny, then allows the TLS listener's clients and
Strimzi's own traffic. Step 2 applies it. Its allows were written from the
manifests and the Strimzi docs, so check them against your own clients before
you rely on them.

Confirm the operator is up. *Illustrative output, not captured.*

```sh
kubectl -n kafka-system get pods
# NAME                                        READY   STATUS    RESTARTS   AGE
# strimzi-cluster-operator-...                1/1     Running   0          1m
```

### 2. Apply the Kafka cluster + node pool + topics

```sh
# Apply the cluster CR FIRST, then the node pool — Strimzi requires
# the cluster to exist before a KafkaNodePool can reference it. With
# `strimzi.io/node-pools: enabled`, the broker count + storage +
# resources live in the KafkaNodePool, not the Kafka CR.
kubectl apply -f examples/bookstore-platform/kafka/cluster.yaml
kubectl apply -f examples/bookstore-platform/kafka/nodepool.yaml
kubectl apply -f examples/bookstore-platform/kafka/topics.yaml
kubectl apply -f examples/bookstore-platform/kafka/networkpolicy.yaml

# Wait for the cluster (~2 minutes on kind)
kubectl -n kafka-system wait kafka/bookstore-platform-kafka \
  --for=condition=Ready --timeout=300s
```

The cluster has one listener, `tls`, on port 9093. It requires mutual TLS
(`authentication: type: tls`): a client presents a certificate that the
clients CA signed, and Strimzi signs one for each KafkaUser. `authorization:
type: simple` then checks each request against that user's ACLs. There is no
plaintext listener, so a pod without a KafkaUser certificate cannot complete
the handshake. Step 5 creates the one KafkaUser this chapter needs.

Deliberate denial (illustrative output, not captured): a client with no
certificate is refused at the handshake, before any ACL is checked.

```sh
# Run from a pod with no KafkaUser certificate. The listener asks for one.
openssl s_client -connect bookstore-platform-kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9093 </dev/null 2>&1 \
  | grep -E 'certificate required|alert|verify' | head -3
# Illustrative: the handshake ends with a TLS alert that asks for a client certificate.
```

What landed: a 3-broker KRaft cluster (combined broker + controller
nodes from the KafkaNodePool) + six topics (`books.cdc`, `orders.placed`,
`payments.completed`, `payments.failed`, `ml.predictions`, `ml.drift`).
Each broker container drops all capabilities, forbids privilege escalation
and runs from a read-only root filesystem. Strimzi mounts `/tmp` from an
emptyDir. The storage is per-broker PVCs of 10 GiB each.

### 3. Apply Meilisearch

The three ExternalSecrets that fill this chapter's Secrets from Vault are in
`search/external-secrets.yaml`. They read through a ClusterSecretStore named
`vault-bookstore-platform`, and this tree does not ship it.
[Part 15 ch.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md)
replaced the shared store with one namespaced SecretStore per tenant, because a
shared store logs in as one identity for every namespace that uses it. The
platform namespaces of this Part need a store of their own. Write a
ClusterSecretStore that lists those namespaces under `spec.conditions`, so that
no tenant namespace can use it, and a Vault role and policy that read only the
platform paths. Neither is written here, and nothing in this Part has been run
against one. 13.06, 13.08, 13.09 and 13.11 read through the same store. Write
`master_key` to Vault before you apply these, as step 4 shows.

Apply the Meilisearch manifest and the ExternalSecrets, then wait for the
rollout. The `#` lines show illustrative output, not captured output.

```sh
kubectl apply -f examples/bookstore-platform/search/meilisearch.yaml
kubectl apply -f examples/bookstore-platform/search/external-secrets.yaml

kubectl -n bookstore-platform-search rollout status statefulset/meilisearch
# statefulset rolling update complete 1 pods at revision ...
```

The image is pinned by digest. The tag `v1.56.0` sits in a comment because a
tag can move and a digest cannot. The image declares no user, so the pod sets
`runAsUser: 65532` itself, and `fsGroup` lets that user write the data
volume.

The namespace denies traffic by default. The `allow-index-clients` policy
admits port 7700 from the tenant namespace and from `kafka-system`, where the
sink runs. Meilisearch makes no outbound calls, so egress stays denied. A
NetworkPolicy takes effect only on a CNI that enforces it; ch.13.02 covers how
to check that on your cluster.

Test it directly (port-forward; production goes through the Istio
gateway). *Illustrative output, not captured.*

```sh
kubectl -n bookstore-platform-search port-forward svc/meilisearch 7700:7700 >/dev/null 2>&1 &
sleep 3
curl -s http://localhost:7700/health
# {"status":"available"}
```

### 4. Pre-create the per-tenant indexes and the scoped keys (idempotent)

Meilisearch auto-creates indexes on first write; explicit pre-creation
sets the primary-key + searchable-attributes up front. The same master-key
session creates the two scoped keys that the workloads use. The master key
goes in a 0600 curl config file, so it stays out of the process list:

```sh
WORK="$(mktemp -d)"
chmod 700 "$WORK"
AUTH_CONF="$WORK/master.conf"
(umask 077; printf 'header = "Authorization: Bearer %s"\n' \
  "$(kubectl -n bookstore-platform-search get secret meilisearch-master-key -o jsonpath='{.data.master-key}' | base64 -d)" > "$AUTH_CONF")

curl -s -K "$AUTH_CONF" -X POST http://localhost:7700/indexes \
  -H "Content-Type: application/json" \
  -d '{"uid":"books-acme-books","primaryKey":"id"}'

curl -s -K "$AUTH_CONF" -X POST http://localhost:7700/indexes/books-acme-books/settings/searchable-attributes \
  -H "Content-Type: application/json" \
  -d '["title","author"]'

# Sink key: documents.add on books-* only. Search key: search on books-* only.
# jq keeps the key field, which the API returns once.
SINK_KEY="$(curl -s -K "$AUTH_CONF" -X POST http://localhost:7700/keys \
  -H "Content-Type: application/json" \
  -d '{"description":"Debezium sink: add documents to books-* only","actions":["documents.add"],"indexes":["books-*"],"expiresAt":"2027-06-30T00:00:00Z"}' | jq -r .key)"

SEARCH_KEY="$(curl -s -K "$AUTH_CONF" -X POST http://localhost:7700/keys \
  -H "Content-Type: application/json" \
  -d '{"description":"books-v2 search service: search books-* only","actions":["search"],"indexes":["books-*"],"expiresAt":"2027-06-30T00:00:00Z"}' | jq -r .key)"

# The search key is the one the service and step 6 use. Keep it in a 0600 file.
SEARCH_AUTH="$WORK/search.conf"
(umask 077; printf 'header = "Authorization: Bearer %s"\n' "$SEARCH_KEY" > "$SEARCH_AUTH")
```

The master key is for setup only. It can create keys, so no workload should
hold it. The sink key goes to Vault at `kv/bookstore-platform/meilisearch` as
`sink_key`. The ExternalSecrets in the platform namespaces read `master_key`
and `sink_key` from that path, and the Debezium role's password from
`kv/bookstore-platform/debezium`. The search key is the tenant's: it goes to
`secret/bookstore-platform/acme-books/meilisearch` as `search_key`, under the
prefix the tenant's Vault policy reads, and the tenant's SecretStore from 15.05
fills it into the tenant namespace. The values come from files, so they stay
out of the process list. *Illustrative: the Vault writes are not captured. Run them against the Vault
that [Part 15 ch.05](../15-day-to-day-production-ops/05-production-secrets-vault-eso.md)
installs.*

```sh
printf '%s' "$SINK_KEY" > "$WORK/sink-key"
printf '%s' "$SEARCH_KEY" > "$WORK/search-key"
vault kv patch kv/bookstore-platform/meilisearch sink_key=@"$WORK/sink-key"
vault kv put -mount=secret bookstore-platform/acme-books/meilisearch \
  search_key=@"$WORK/search-key"
unset SINK_KEY SEARCH_KEY
rm -rf "$WORK"
```

Write `master_key` the same way before the first ExternalSecret syncs: generate
it into a file with `openssl rand -base64 32`, and `vault kv put` it with
`master_key=@<file>`. Write the Debezium password the same way, and set the same
value on the Postgres `debezium` role in ch.13.03. Both keys expire on
2027-06-30, so rotate them before then.

Deliberate denial (illustrative output, not captured): the search key cannot
create keys. Only the master key can.

```sh
curl -s -K "$SEARCH_AUTH" -X POST http://localhost:7700/keys \
  -H "Content-Type: application/json" \
  -d '{"description":"should be refused","actions":["search"],"indexes":["*"],"expiresAt":"2027-06-30T00:00:00Z"}'
# Illustrative: an error response, with no key in the body.
```

### 5. Apply the Debezium connector

```sh
# Wait for CNPG primary to be Ready and wal_level=logical
# (CNPG sets this when `postgresql.parameters.wal_level: logical` is in
# the Cluster CR; ch.13.03 walks the CNPG install).

kubectl apply -f examples/bookstore-platform/search/debezium-connector.yaml

# KafkaConnect builds the Connect image with the Debezium + Camel
# plugins; first start takes ~3 minutes on kind.
kubectl -n kafka-system wait kafkaconnect/bookstore-platform-connect \
  --for=condition=Ready --timeout=600s
```

The KafkaConnect spec mounts two Secrets through Strimzi's
`externalConfiguration`: `meilisearch-sink-key`, which holds the sink's
scoped key, and `debezium-postgres`, which holds the Postgres password. Strimzi
mounts each Secret under `/opt/kafka/external-configuration/<volume>/`, one
file per key. The connectors read those files with the
**DirectoryConfigProvider** and `${dir:<directory>:<file>}`. The sink's
`camel.sink.endpoint.authMethod: Bearer` and `authBearerToken` options send
`Authorization: Bearer <key>`, with the key read from
`${dir:/opt/kafka/external-configuration/meili-sink:api-key}`. Neither value
appears in the connector spec or in `kubectl describe` output. Without that
header every sink write returns 401 (Meilisearch runs with `--env production`)
and the index never receives a row. This config does not set a JSON
`Content-Type`, and Meilisearch rejects a document POST without
`application/json`. Step 6 shows whether the rows arrive, so check the sink's
log there if they do not.

The Connect worker authenticates as the KafkaUser `bookstore-platform-connect`
from the same file. Its certificate lands in a Secret of that name. Its ACLs
cover `books.cdc`, the Connect internal topics and the sink's consumer group,
and nothing else.

Each plugin artifact carries a `sha512sum`. Strimzi verifies the download
against it while it builds the Connect image, so a swapped archive fails the
build. Debezium names its topic `bookstore-platform.public.books`. The
`route` transform renames it to `books.cdc`, the topic the ACLs, the sink and
`kafka/topics.yaml` all use.

> **If the KafkaConnector does not reach Ready after 10 minutes:**
> `kubectl -n kafka-system logs -l app.kubernetes.io/component=cdc` —
> look for `JDBC driver not found` (wrong plugin) or `FATAL: logical
> replication is not allowed for user` (missing REPLICATION role on the
> Postgres user).

Check both connectors land in RUNNING state. *Illustrative output, not
captured.*

```sh
kubectl -n kafka-system get kafkaconnector
# NAME                       CLUSTER                       CONNECTOR CLASS                                     MAX TASKS   READY
# books-cdc-source           bookstore-platform-connect    io.debezium.connector.postgresql.PostgresConnector  1           True
# books-meilisearch-sink     bookstore-platform-connect    org.apache.camel.kafkaconnector...                  1           True
```

### 6. Walk a row through the pipeline

```sh
# Insert a row into the books table (use the Postgres in CNPG; here the
# psql variable $DB_DSN is set from the per-tenant Secret).
psql "$DB_DSN" <<'SQL'
INSERT INTO books (id, title, author, price, tenant_id)
VALUES ('k8s-in-action', 'Kubernetes in Action', 'Marko Luksa', 49.99, 'acme-books');
SQL

# Wait ~3 seconds for the CDC pipeline.
sleep 5

# Verify the document is in Meilisearch. The search uses the search key from
# step 4, as the service does. The output below is illustrative, not captured.
curl -s -K "$SEARCH_AUTH" "http://localhost:7700/indexes/books-acme-books/search?q=kubernetes" | jq .
# {
#   "hits": [
#     {
#       "id": "k8s-in-action",
#       "title": "Kubernetes in Action",
#       "author": "Marko Luksa",
#       "price": 49.99,
#       "tenant_id": "acme-books"
#     }
#   ],
#   "query": "kubernetes",
#   "processingTimeMs": 2,
#   "limit": 20,
#   "offset": 0,
#   "estimatedTotalHits": 1
# }
```

### 7. Deploy the v2 search service

```sh
# Build the image (the source is at examples/bookstore-platform/app/search/)
cd examples/bookstore-platform/app/search
docker build -t bookstore-platform/search:dev .
kind load docker-image bookstore-platform/search:dev --name bookstore-platform-us-east

# Create the tenant ns + apply
kubectl create namespace bookstore-platform-acme-books --dry-run=client -o yaml | \
  kubectl label --local -f - \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted -o yaml | \
  kubectl apply -f -

kubectl apply -f external-secret.yaml -f deployment.yaml -f service.yaml
kubectl -n bookstore-platform-acme-books rollout status deployment/search
```

The Deployment reads `MEILI_API_KEY`, the service's search key, from the
`meilisearch-search-key` Secret. The ExternalSecret in
`app/search/external-secret.yaml` creates that Secret from Vault, so apply it
after step 4 has stored the key. The service never holds the master key. The `search-egress` policy
allows out only DNS and port 7700. On a tenant namespace that 13.02's
Composition stamped, the default-deny is already in place and this policy is
the only egress allowed.

### 8. Curl the v2 endpoint through the Istio gateway

With the JWT obtained in [13.04 step 3](04-real-auth-keycloak-irsa-istio-jwt.md):

```sh
# EDGE_CA is the edge CA certificate file exported in 13.07. The output below
# is illustrative, not captured.
curl -s --cacert "$EDGE_CA" -H "Authorization: Bearer $JWT" \
  "https://localhost:8443/api/v2/search?q=kuberentes"   # typo!
# {"hits":[{"id":"k8s-in-action","title":"Kubernetes in Action",...}],
#  "query":"kuberentes","processingTimeMs":3, ...}
```

Note the typo `kuberentes` matched `Kubernetes` — that's Meilisearch's
typo tolerance, the headline feature v1's SQL `LIKE` could not give.

## How it works under the hood

**Postgres logical replication is the WAL stream.** Debezium asks
Postgres to create a **replication slot** (`debezium_books`) and a
**publication** (also `debezium_books`). The slot is a server-side
cursor over the WAL; the publication declares which tables are
streamed. Debezium pulls the stream over the standard Postgres
replication protocol — the same protocol CNPG uses for its own
streaming standbys. Postgres `wal_level = logical` is required; with
`wal_level = replica` the WAL only carries page-level changes (enough
for physical streaming, not enough for row-level CDC).

**CDC is at-least-once.** A network blip between Debezium and Kafka
might cause Debezium to replay a WAL position it already shipped; the
same row event arrives twice. The sink connector handles this by
**idempotent writes** — Meilisearch's document-add API is a deterministic
upsert on the primary key. Adding a document with `id=k8s-in-action`
twice produces the same final state (the second write replaces the
first; Meilisearch tracks version numbers internally). No deduplication
work required at the application layer.

**Per-tenant index naming via SMT.** The Camel HTTP sink supports a
Single Message Transform that rewrites the URL template at runtime:
`/indexes/books-{{tenant_id}}/documents`. The transform reads the
`tenant_id` field from each Kafka message and substitutes it. One sink
connector instance handles N tenants — far simpler than N connector
instances. The chapter ships this pattern; the alternative ("route to
N topics, one sink per topic") is sketched in the README.

**Restart and replay semantics.** Debezium has two snapshot modes:

- `initial` — at first connector start, Debezium runs a full snapshot
  of the `books` table (all existing rows), then transitions to
  streaming. **This is what the connector ships.**
- `never` — Debezium starts at the current WAL position only; no
  backfill. Useful when the index is rebuilt by other means or
  pre-warmed.

On restart, Debezium reads the last-committed offset (stored in the
Connect cluster's offset topic) and resumes from that WAL position. If
the slot has been retained on the Postgres side (default), this works
transparently. If the slot was dropped (e.g. by a manual `DROP REPLICATION
SLOT`), Debezium reverts to `initial` mode and re-snapshots — usually
fine, but a multi-minute pause on a large table.

**Reindexing — blue-green vs rolling.** When the schema changes (a
new searchable attribute; a new ranking rule), you re-index. Two
strategies:

- **Rolling** — apply the new settings to the live index; Meilisearch
  re-indexes in the background; queries may temporarily lack the new
  ranking. Simple; brief inconsistency.
- **Blue-green** — index into `books-acme-books-v2` (new); swap the
  alias `books-acme-books` to point at `-v2` when ready; delete `-v1`.
  Zero inconsistency at query time; harder to operate. Production
  picks blue-green for any change that affects ranking; rolling for
  attribute-only changes.

## Production notes

> **In production:** **Reindexing strategies must be drilled.** A
> teammate adds a new searchable attribute, applies the schema change
> live, and the rolling reindex saturates the Meilisearch CPU — queries
> time out under load. The blue-green pattern + a `kubectl rollout
> status statefulset/meilisearch` runbook keeps the live index serving
> while the new one warms. Drill it in staging; rehearse the alias-swap
> command. The chapter's runbook (13.12) ships a step-by-step.

> **In production:** **The slow query in Postgres because the WAL got
> replicated to N consumers footgun.** Each replication slot is a
> server-side cursor that retains WAL until the consumer acknowledges
> it. If Debezium falls behind (or is paused for maintenance), the WAL
> grows unbounded on the primary — disk fills, the primary crashes.
> Set `max_slot_wal_keep_size` (Postgres 13+) to cap retained WAL
> per-slot; set Prometheus alerts on `pg_replication_slots.confirmed_
> flush_lsn` lag. The chapter cross-refs Part 06 ch.01 for the
> alerting shape.

> **In production:** **Meilisearch is stateful — back it up.** The
> StatefulSet's PVC is the source of truth; lose the PVC, lose the
> indexes. Meilisearch's snapshot API
> (`POST /snapshots`) writes a tarball to the data directory; a
> CronJob that copies the snapshot to S3 nightly is the minimum
> backup. The snapshot holds every tenant's documents, so give the bucket the
> same access rules as tenant data. Restoring is `meilisearch
> --import-snapshot snapshot.snapshot`, with the master key in
> `MEILI_MASTER_KEY` rather than a flag, because `ps` shows flags.
> Reindexing from Postgres via Debezium also works
> as a recovery — but at hours-of-downtime cost for >10M docs.

> **In production:** **Cross-region search is eventually consistent;
> accept it.** A row inserted in us-east takes ~2-30 seconds to appear
> in the ap-southeast Meilisearch (CNPG replication lag + Debezium
> processing + Meilisearch indexing). For e-commerce this is fine —
> a customer browsing books does not need to see the *latest*
> millisecond. For inventory ("is this book in stock") run a separate
> check against the primary on the order path; don't depend on search
> for the buy decision. The chapter's runbook (13.12) calls this
> failure mode out explicitly.

> **In production:** **Index-as-a-throwaway pattern.** Treat the search
> index as a derived store you can always rebuild from Postgres. If
> the index gets corrupted, mis-indexed, or polluted by a bug, the
> recovery is "drop the index, restart the connector with
> `snapshot.mode: initial`, wait for the backfill". This is the same
> shape the chapter taught in [Part 12 ch.07](../12-kubernetes-for-machine-learning/07-ml-pipelines-and-workflows.md)
> for ML artifacts ("the model is recomputable from the training
> data") — applied to search.

## Quick Reference

```sh
# Install Strimzi (pinned), in a namespace labelled baseline
kubectl create namespace kafka-system
kubectl label namespace kafka-system \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
STRIMZI_VERSION="0.40.0"
helm repo add strimzi https://strimzi.io/charts/
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --version "$STRIMZI_VERSION" -n kafka-system \
  -f examples/bookstore-platform/kafka/strimzi-values.yaml --wait

# Kafka cluster + node pool + topics (cluster must exist before the pool)
kubectl apply -f examples/bookstore-platform/kafka/cluster.yaml
kubectl apply -f examples/bookstore-platform/kafka/nodepool.yaml
kubectl apply -f examples/bookstore-platform/kafka/topics.yaml

# Meilisearch and its ExternalSecrets
kubectl apply -f examples/bookstore-platform/search/meilisearch.yaml
kubectl apply -f examples/bookstore-platform/search/external-secrets.yaml

# Debezium + sink
kubectl apply -f examples/bookstore-platform/search/debezium-connector.yaml

# Confirm the pipeline
kubectl -n kafka-system get kafka,kafkatopic,kafkaconnect,kafkaconnector
kubectl -n bookstore-platform-search get statefulset,svc

# v2 search service
kubectl apply -f examples/bookstore-platform/app/search/external-secret.yaml
kubectl apply -f examples/bookstore-platform/app/search/deployment.yaml
kubectl apply -f examples/bookstore-platform/app/search/service.yaml
```

Minimal skeletons:

```yaml
# Strimzi KafkaConnector for Debezium Postgres
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: <NAME>
  namespace: kafka-system
  labels:
    strimzi.io/cluster: <CONNECT-CLUSTER-NAME>
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  tasksMax: 1
  config:
    database.hostname: <CNPG-RW-SVC>
    database.port: "5432"
    database.user: debezium
    database.password: "${dir:/opt/kafka/external-configuration/pg:password}"
    database.dbname: <DB>
    table.include.list: public.<TABLE>
    slot.name: <SLOT>
    publication.name: <PUBLICATION>
    snapshot.mode: initial
    topic.prefix: <PREFIX>
---
# Meilisearch index settings (curl, not YAML — Meilisearch has no CRD)
# POST /indexes/<INDEX>/settings/searchable-attributes ["title","author"]
# POST /indexes/<INDEX>/settings/filterable-attributes ["price","tenant_id"]
```

Checklist (search wired correctly when all six are yes):

- [ ] Postgres `wal_level = logical` AND a replication slot named in the
      Debezium config exists.
- [ ] The Kafka listener is `tls` only, `authorization` is `simple`, and
      the one KafkaUser's ACLs name only the topics it uses.
- [ ] `KafkaTopic books.cdc` is Ready with 3 partitions / 3 replicas.
- [ ] `KafkaConnect bookstore-platform-connect` builds successfully and
      both `KafkaConnector`s are Ready.
- [ ] Per-tenant indexes exist in Meilisearch (`books-<TENANT>` for each
      onboarded tenant) and accept a `/search?q=...` query.
- [ ] Cross-region: each region's Debezium has its own slot on the local
      CNPG replica; lag is < 30 s in steady state.

## Test your understanding

> Try each before opening the answer drawer. The act of trying is the exercise; the answer is the check.

1. **Why CDC via Debezium → Kafka → Meilisearch instead of "update the search index from the app"?**
   <details><summary>Show answer</summary>

   App-driven sync has three failure modes: (1) **Dual-write inconsistency** — app commits to Postgres but crashes before publishing to Meilisearch; search and DB diverge silently. (2) **Coupling** — every service that writes to `books` needs to know about the search index, doubling the surface area. (3) **No replay** — if Meilisearch crashes and you need to reindex, app code has to scan and republish. CDC solves all three: Debezium reads the WAL (which Postgres commits atomically), publishes to Kafka (durable), and the search-index consumer is decoupled and replayable from any offset. The DB is the source of truth; the index is a projection.

   </details>

2. **You're designing per-tenant index isolation. Compare "index-per-tenant" vs "single index with tenant-id filter."**
   <details><summary>Show answer</summary>

   **Index-per-tenant** (`books-acme`, `books-bigco`): strong isolation, tenant A can't accidentally search tenant B's data, you can drop tenant B's index without touching A, you can scale per-tenant. Cons: more indices (Meilisearch RAM/disk overhead), schema changes touch N indices, cross-tenant analytics need fan-out. **Single index + filter**: cheaper at low tenant count, simpler schema evolution, easier cross-tenant analytics. Cons: filter-bypass is a serious bug (one missed `WHERE tenant_id=X` in the search code leaks data), index size grows unboundedly, no per-tenant tuning. v2 picks index-per-tenant because the isolation guarantee is non-negotiable. Below ~100 tenants this is cheap; above that you reassess.

   </details>

3. **Debezium replication slot on the Postgres primary is at 12 GB and growing — Postgres disk is filling. What's happening and what do you do?**
   <details><summary>Show answer</summary>

   Postgres retains WAL segments until every replication slot has consumed them. Debezium is either (a) down/slow and not consuming, (b) the Kafka cluster is down so the connector retries forever holding the slot, (c) the connector was deleted but its slot wasn't dropped. Immediate: `SELECT * FROM pg_replication_slots` — which slot is at the tail? If Debezium is down: bring it back up so it catches up. If the connector is gone: `SELECT pg_drop_replication_slot('slot_name')` *only after* confirming you'll do a full reindex (you've lost the change events past that point). Prevention: alert on slot lag, set `max_slot_wal_keep_size` to bound WAL retention (Postgres 13+) at the cost of breaking lagging slots.

   </details>

4. **Hands-on: insert 1000 rows into `books`, watch them flow Postgres → Debezium → Kafka → Meilisearch. Now stop the Meilisearch sink connector for 5 minutes, insert another 100 rows, then resume. What do you see?**
   <details><summary>What you should see</summary>

   While the sink connector is down, Debezium continues writing to Kafka — events accumulate in the topic. Postgres WAL retention holds because the Debezium slot is still consuming. When the sink resumes, Kafka has the consumer offset stored; the sink connector reads from its last committed offset and catches up. The 100 rows flow into Meilisearch as if no outage happened. RTT for the catch-up depends on throughput. This is the durability property of the Kafka log: consumers can be down, the producer keeps producing, the data is safe.

   </details>

5. **Schema change: you add a `published_at` column to `books`. What's the safe order of operations across Postgres → Debezium → Meilisearch?**
   <details><summary>Show answer</summary>

   (1) Add the column to Postgres with a default (or `NULL`). (2) Debezium will pick it up automatically on the next change event — Debezium produces full row state, so the new field appears in Kafka with subsequent events. Older rows have no event for the new column (their last update predates the schema change). (3) Backfill the Meilisearch index by either (a) updating every Postgres row (touching `updated_at`) to force a CDC event per row, or (b) running a manual reindex that reads from Postgres directly. (4) Add the new field to the Meilisearch index settings (`searchableAttributes`, `filterableAttributes`). Order matters: never delete a column from Postgres without first removing references in downstream consumers; never add a NOT NULL column without a default. Schema evolution is forward-only at the events layer.

   </details>

6. **The sink's key is copied out of a Connect pod. What can the holder do, what can't they do, and what limits the damage?**
   <details><summary>Show answer</summary>

   The key holds `documents.add` on `books-*`. The holder can write or overwrite documents in every index the pattern covers, so search results can be poisoned. The holder cannot search, delete an index, or list or create keys. The limits are the scope, the expiry and rotation: create a new key with the master key, write it to Vault, and reload the connector so it reads the new file. The master key never sits in the Connect pod, so the holder cannot mint keys of their own.

   </details>

## Further reading

- **Ibryam & Huß, _Kubernetes Patterns_ 2e — *Event Sourcing* (ch.7)**
  — the change-data-capture + log-as-source-of-truth pattern this
  chapter specialises to Postgres -> Kafka -> Meilisearch.
- **Rosso et al., _Production Kubernetes_, ch.6 — "Stateful workloads"**
  — the StatefulSet + PVC shape Meilisearch needs.
- Official: **Meilisearch docs (Kubernetes deploy, scaling, snapshots)**
  <https://www.meilisearch.com/docs>; **Debezium Postgres connector**
  <https://debezium.io/documentation/reference/stable/connectors/postgresql.html>;
  **Strimzi KafkaConnect docs**
  <https://strimzi.io/docs/operators/latest/configuring.html#assembly-deployment-configuration-kafka-connect-str>;
  **Camel Kafka Connectors** (HTTP sink reference)
  <https://camel.apache.org/camel-kafka-connector/latest/connectors/camel-http-sink-kafka-sink-connector.html>.
- Official: **Meilisearch API keys** (actions, index patterns, expiry)
  <https://www.meilisearch.com/docs/learn/security/master_api_keys>;
  **Strimzi 0.40.0 docs**, the configuring guide (plugin `sha512sum`)
  <https://strimzi.io/docs/operators/0.40.0/configuring.html> and the
  deploying guide (external configuration, the cluster and clients CAs)
  <https://strimzi.io/docs/operators/0.40.0/deploying.html>.
