# catalog — Bookstore Platform v2 catalog service

The catalog service for the Bookstore Platform v2 reference application:
a thin Go service that owns the **books** entity, fronts it with a
JSON+REST API, persists it in Postgres, and exposes Prometheus metrics
on `/metrics`.

Promoted from the Phase 16 stub to a real, tested, benchmarked service
in May 2026 — the first of the Platform v2 services to graduate. See
[`BENCHMARKS.md`](BENCHMARKS.md) for the empirical numbers.

## API

| Method | Path | Description | Body | Returns |
|---|---|---|---|---|
| GET | `/healthz` | Liveness — process up and serving | — | `200 {"status":"ok"}` |
| GET | `/readyz` | Readiness — DB round-trip succeeds | — | `200 {"status":"ok"}` / `503` |
| GET | `/metrics` | Prometheus scrape | — | `200 text/plain` |
| GET | `/books` | List books (paginated) | `?limit=N&offset=M` | `200 {"books":[…],"limit":N,"offset":M}` |
| GET | `/books/{id}` | Fetch one book | — | `200 Book` / `404` |
| POST | `/books` | Create | `Book JSON` | `201 Book` / `400` |
| PUT | `/books/{id}` | Replace | `Book JSON` (id from path) | `200 Book` / `404` / `400` |
| DELETE | `/books/{id}` | Delete | — | `204` / `404` |

`Book` shape:

```json
{
  "id":     "string (required, free-form)",
  "title":  "string (required)",
  "author": "string (required)",
  "isbn":   "string (required, 10 or 13 digits — hyphens and spaces stripped server-side)"
}
```

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `DB_DSN` | *(unset → in-memory repo)* | Postgres connection string. Format: `postgres://user:pass@host:port/db?sslmode=disable&pool_max_conns=25`. Empty → service starts with a 3-book in-memory seed (handy for local dev / smoke tests). |

## Run it

### Locally, no DB needed

```bash
go run .
# service comes up on :8080 with three seeded books
```

### Locally, against a real Postgres

```bash
docker run -d --name catalog-pg -p 5432:5432 \
  -e POSTGRES_USER=catalog -e POSTGRES_PASSWORD=catalog -e POSTGRES_DB=catalog \
  postgres:16-alpine

export DB_DSN="postgres://catalog:catalog@localhost:5432/catalog?sslmode=disable"
go run .
```

The service applies an idempotent `CREATE TABLE IF NOT EXISTS books (…)`
on boot, so the first run on a fresh DB is enough — no separate migration
step required. In production, the migration would live in a Kubernetes
Job (see Part 06.04 of the guide for the pattern).

### In Kubernetes

```bash
kubectl apply -f deployment.yaml -f service.yaml
# (Deployment expects an image at bookstore/catalog:dev — build with
#  `docker build -t bookstore/catalog:dev .`)
```

## Develop

```bash
# unit tests (fast; no Docker)
go test -short ./...

# integration tests (spins up a real Postgres via testcontainers-go; needs Docker)
go test ./...

# coverage
go test -cover -coverprofile=cover.out ./...
go tool cover -html=cover.out

# benchmarks (see BENCHMARKS.md for the latest committed numbers)
go test -run='^$' -bench=. -benchmem ./...

# end-to-end load test (k6 required)
k6 run bench/load.js
```

## Layout

```
catalog/
├── BENCHMARKS.md           — committed perf numbers + methodology
├── Dockerfile              — multi-stage, distroless final image, nonroot
├── README.md               — this file
├── bench/load.js           — k6 end-to-end load test
├── deployment.yaml         — Kubernetes Deployment manifest
├── service.yaml            — Kubernetes Service manifest
├── go.mod, go.sum          — dependency lock
├── main.go                 — entry point + wiring
├── handlers.go             — HTTP handlers + middleware
├── handlers_test.go        — handler tests (table-driven, in-memory repo)
├── model.go                — domain types (Book) + validation
├── model_test.go           — validation tests
├── repository.go           — Repository interface + PostgresRepo + MemRepo
├── repository_test.go      — integration tests (testcontainers-go + Postgres)
├── metrics.go              — Prometheus collectors + /metrics handler
└── bench_test.go           — Go in-process benchmarks
```

## Observability

* **Logs** — JSON-structured via `log/slog` to stdout. One line per
  request with `method`, `path`, `status`, `duration_ms`.
* **Metrics** — Prometheus exposition on `/metrics`. Custom series:
  * `catalog_http_requests_total{method,path,status}` — counter,
    status normalised to class (`2xx`, `4xx`, `5xx`) to keep label
    cardinality bounded.
  * `catalog_http_request_duration_seconds{method,path}` — histogram,
    buckets tuned to 1ms–5s.
  * Plus the standard `go_*` and `process_*` collectors.
* **Traces** — not yet emitted; OpenTelemetry instrumentation is the
  next planned change (see the project [CHANGELOG.md](../../../../../CHANGELOG.md)).

## Tests + coverage

Last full-suite run (`go test -count=1 -cover ./...` with Docker available
for integration tests): **75.0% statement coverage** across the package,
all unit + integration tests passing. The remaining 25% is `main.go`'s
process wiring + the Postgres bootstrap path — both exercised in the
manual Kubernetes deploy rather than unit-level.

## Where this fits in the guide

* The architecture (one bounded context per service, repo pattern, in-memory
  fake for tests) is established in **ch.13.01** ("the Bookstore Platform
  shape").
* The deployment manifest + Helm-chart wiring is teased in **ch.13.05**.
* The Prometheus + slog instrumentation pattern is from **Part 06**
  (production-readiness) and **Part 09** (observability).
* The benchmark methodology + thresholds is the worked example for
  **ch.06.05** ("how to put numbers on your service").
