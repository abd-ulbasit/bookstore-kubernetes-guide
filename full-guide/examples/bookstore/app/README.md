# Bookstore — example application source

Minimal, **real, runnable** source for the Bookstore microservices used
throughout the guide. The code is deliberately tiny: each service is a vehicle
for Kubernetes concepts, not a production e-commerce system. Every Go service is
a single static binary in a distroless image; storefront is static files on
nginx.

All services run unprivileged and listen on `:8080` (override with `PORT`). The
Go services emit **structured JSON logs** (Go `log/slog`), expose Prometheus
`/metrics`, and shut down gracefully on `SIGTERM`.

## Services

| Service | Lang | Image tag (used by chapters) | Listens | Role |
|---|---|---|---|---|
| `catalog` | Go | `bookstore/catalog:dev` | `:8080` | Book listing API; reads Postgres, caches in Redis |
| `orders` | Go | `bookstore/orders:dev` | `:8080` | Place orders; writes Postgres, publishes to RabbitMQ |
| `payments-worker` | Go | `bookstore/payments-worker:dev` | `:8080` (health/metrics only) | Consumes RabbitMQ `orders`, "processes" payments |
| `storefront` | static/nginx | `bookstore/storefront:dev` | `:8080` | Browser UI; fetches `/api/books`, posts `/api/orders` |

`postgres`, `redis`, `rabbitmq` use upstream official images (no source here).

## Endpoints

**catalog**
- `GET /healthz` — liveness, always `200 {"status":"ok"}`
- `GET /readyz` — readiness; `503` if a configured DB/cache is unreachable
- `GET /books` — JSON array of books (Postgres if `DB_DSN` set, else in-memory sample; cached in Redis if `REDIS_ADDR` set; sets `X-Cache: HIT|MISS`)
- `GET /metrics` — Prometheus (`http_requests_total`, `http_request_duration_seconds`)

**orders**
- `POST /orders` — body `{"book_id":<INT>,"qty":<INT>}`; `201` with `{order_id,status}`; `400` on invalid body
- `GET /healthz`, `GET /readyz`, `GET /metrics` (adds `orders_placed_total`)

**payments-worker**
- `GET /healthz`, `GET /metrics` (adds `payments_processed_total`)
- No HTTP business endpoint — it is a queue consumer.

**storefront**
- `GET /` — the UI; `GET /healthz` — `200 {"status":"ok"}`

## Configuration (environment variables)

| Var | Services | Default | Meaning |
|---|---|---|---|
| `PORT` | all | `8080` | HTTP listen port |
| `LOG_LEVEL` | go services | `info` | `debug`/`info`/`warn`/`error` (slog) |
| `DB_DSN` | catalog, orders | _(unset)_ | Postgres DSN, e.g. `postgres://user:pass@postgres:5432/bookstore`. Unset → catalog serves sample data; orders log instead of persisting |
| `REDIS_ADDR` | catalog | _(unset)_ | Redis `host:port`. Set → catalog caches the listing (30s TTL) |
| `AMQP_URL` | orders, payments-worker | _(unset)_ | RabbitMQ URL, e.g. `amqp://guest:guest@rabbitmq:5672/`. Unset → orders skip publish; worker idles with a 30s heartbeat |

Expected schema when `DB_DSN` is set (created by the migration Job in a later
chapter):

```sql
CREATE TABLE books  (id SERIAL PRIMARY KEY, title TEXT, author TEXT, price NUMERIC);
CREATE TABLE orders (id SERIAL PRIMARY KEY, book_id INT, qty INT, created_at TIMESTAMPTZ);
```

## Build the images

Each service builds independently (separate Go modules, multi-stage Dockerfile
→ `gcr.io/distroless/static:nonroot`):

```sh
docker build -t bookstore/catalog:dev         ./catalog
docker build -t bookstore/orders:dev          ./orders
docker build -t bookstore/payments-worker:dev ./payments-worker
docker build -t bookstore/storefront:dev      ./storefront
```

(When using kind: `kind load docker-image bookstore/catalog:dev` etc. With
k3d: `k3d image import bookstore/catalog:dev`.)

## Run locally with plain Docker (no Kubernetes)

Zero-dependency mode — no Postgres/Redis/RabbitMQ needed:

```sh
docker run --rm -p 8080:8080 bookstore/catalog:dev
curl -s localhost:8080/books        # sample books
curl -s localhost:8080/healthz
curl -s localhost:8080/metrics | head

docker run --rm -p 8081:8080 bookstore/orders:dev
curl -s -X POST localhost:8081/orders \
  -H 'Content-Type: application/json' -d '{"book_id":1,"qty":2}'

docker run --rm -p 8082:8080 bookstore/payments-worker:dev   # idles, heartbeats
docker run --rm -p 8083:8080 bookstore/storefront:dev        # open http://localhost:8083
```

## Develop without Docker

```sh
cd catalog && go mod tidy && go vet ./... && go run .
```

The same applies to `orders` and `payments-worker`.
