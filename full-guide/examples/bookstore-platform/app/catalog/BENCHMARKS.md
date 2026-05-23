# Catalog service — benchmarks

Two benchmarking surfaces:

1. **In-process Go benchmarks** (`bench_test.go`) — measure the handler
   chain end-to-end *without* network I/O, so the numbers reflect the
   service's own work. Run with: `go test -run='^$' -bench=. -benchmem ./...`
2. **End-to-end k6 load test** (`bench/load.js`) — drives real HTTP
   traffic at constant + ramping arrival rates with pass/fail thresholds.
   Run with: `k6 run bench/load.js` (service must be listening).

The Go benchmarks below are the **authoritative committed numbers** because
they're reproducible by anyone with `go` installed, no extra services. The
k6 thresholds are tuned to those numbers (with headroom for network +
kernel scheduling latency).

---

## In-process benchmark results

Captured **2026-05-23** on:
* Hardware: Apple M1 Pro (8 cores, 32 GB RAM)
* OS: macOS 25.5.0 (Darwin)
* Go: 1.26.2
* Storage: in-memory `MemRepo` (eliminates DB I/O from the numbers — the
  k6 run below adds the Postgres round-trip back in)

```text
goos: darwin
goarch: arm64
pkg: github.com/bookstore-platform/catalog
cpu: Apple M1 Pro

BenchmarkHealthz-8         496748       2462 ns/op    1481 B/op     17 allocs/op
BenchmarkGetBook_Hot-8     484872       2486 ns/op    1506 B/op     19 allocs/op
BenchmarkListBooks_100-8    39006      30994 ns/op   13132 B/op     30 allocs/op
BenchmarkCreateBook-8      157602       7786 ns/op   14653 B/op     45 allocs/op
BenchmarkMetricsScrape-8     7467     156479 ns/op  113719 B/op    725 allocs/op
BenchmarkBookValidate-8    648520       1950 ns/op    6823 B/op      5 allocs/op
```

### What this means

| Benchmark | Latency | Single-core throughput ceiling | Notes |
|---|---:|---:|---|
| `Healthz` | **2.5 µs/req** | ~406 k req/s | Liveness probe noise floor; anything heavier here is a regression. |
| `GetBook_Hot` (in-memory) | **2.5 µs/req** | ~402 k req/s | Single-row read, hot path, no allocation pressure. The Postgres path adds the network + query parse cost — see the k6 run below. |
| `ListBooks` (page of 50 / 100) | **31 µs/req** | ~32 k req/s | Pagination + JSON encode of a 50-element array. Allocation count (30) is dominated by the JSON encoder's per-field intermediate buffers. |
| `CreateBook` (POST) | **7.8 µs/req** | ~128 k req/s | Full POST path: JSON decode → validate (regex + trim + uppercase) → in-memory insert. |
| `MetricsScrape` (warm) | **156 µs/scrape** | ~6.4 k scrapes/s | Prometheus scrapes typically run every 15s in production; 156µs is comfortably below the "scrape took too long" threshold (>100ms is concerning). |
| `BookValidate` (alone) | **2.0 µs/op** | ~513 k ops/s | The regex compile happens once (package-level `isbnRE`); per-call cost is just match + string normalisation. |

### Allocation profile observations

* The **17-allocation floor** on `Healthz` is the per-request HTTP machinery
  cost (request parsing + status recorder + response header map). Hard to
  drive below this on Go's `net/http` without taking on a custom router.
* `MetricsScrape` at 725 allocations is dominated by the Prometheus client's
  text-format encoding. The compact protobuf encoding (toggle via
  `Accept: application/vnd.google.protobuf` on the scrape request) cuts
  this by ~70% when the scraper supports it (Prometheus does, since 2.x).
* `ListBooks` at 30 allocations is largely the inevitable cost of the
  result-set JSON encode. A streaming encoder could shave allocations at
  the cost of code complexity — not worth it at this latency.

---

## End-to-end k6 results

The k6 script at [`bench/load.js`](bench/load.js) runs two concurrent
scenarios for ~30 seconds:

* **`reads`** — `constant-arrival-rate` at 1000 RPS of `GET /books/{id}`
* **`writes`** — `ramping-arrival-rate` to 100 RPS of `POST /books`

with thresholds:

```js
thresholds: {
  'http_req_duration{scenario:reads}': ['p(95)<50', 'p(99)<100'],
  'http_req_failed': ['rate<0.01'],
  'checks': ['rate>0.99'],
}
```

### Reproducing locally

The CI-equivalent (against a real Postgres) is:

```bash
# 1. spin up a Postgres next to the service
docker run -d --name catalog-pg \
  -p 5432:5432 \
  -e POSTGRES_USER=catalog \
  -e POSTGRES_PASSWORD=catalog \
  -e POSTGRES_DB=catalog \
  postgres:16-alpine

# 2. run the service against it
export DB_DSN="postgres://catalog:catalog@localhost:5432/catalog?sslmode=disable"
go run .

# 3. (another terminal) drive load
k6 run --summary-trend-stats="avg,min,med,max,p(50),p(95),p(99),p(99.9)" \
    bench/load.js

# 4. tidy up
docker rm -f catalog-pg
```

### Expected numbers

Based on the in-process benchmark above plus the typical kernel + loopback
overhead (~30-80µs per request on macOS via colima / Linux with cgroup-v2):

| Metric | In-process | Expected over loopback (k6 vs local service) |
|---|---:|---:|
| GET /books/{id} p50 | ~2.5 µs | ~0.3 – 1 ms |
| GET /books/{id} p95 | — | ~3 – 10 ms |
| GET /books/{id} p99 | — | ~10 – 30 ms |
| POST /books p95 | — | ~5 – 15 ms (incl. DB INSERT) |

If your run measures latencies materially worse than these, the most
common causes are:

1. **The DB is sized too small.** The default Postgres image has tiny
   `shared_buffers` and `work_mem`. Bump `shared_buffers=256MB` for the
   load test.
2. **Connection pool too small.** `PostgresRepo.MaxConns` defaults to 8.
   For a sustained 1000 RPS read load against Postgres, raise it to
   25–50 (override via the DSN's `pool_max_conns` parameter).
3. **macOS Docker overhead.** Colima/Lima/Docker-Desktop on macOS add
   ~0.3–1 ms of overhead per network hop vs. native Linux. Numbers on
   a Linux CI runner will be 2-3× tighter.

---

## How these numbers travel

* The Go benchmarks above re-run on every push to `main` as part of the
  catalog-service test job (see
  [`.github/workflows/example-trees-check.yml`](../../../../../.github/workflows/example-trees-check.yml)),
  with a `benchstat`-driven comparison to catch regressions ≥10%.
* The k6 run is *not* part of CI by default — load tests on shared
  runners are noisy and produce false positives. Run it manually before
  cutting a release, or against a dedicated soak-test environment.

---

## Methodology notes

* Each Go benchmark uses Go 1.22+'s `b.Loop()` (not `for i := 0; i < b.N`)
  so the compiler keeps the loop body honest about cleanup. Allocations
  are reported via `-benchmem`.
* All benchmarks use `httptest.NewRecorder` — no real TCP, no kernel
  scheduling jitter. This makes the numbers tight + reproducible but
  excludes the network-stack cost.
* The MemRepo path is used for in-process tests so the DB isn't on the
  hot path. The k6 run uses the Postgres path because that's what
  matters end-to-end.
* No warmup phase on the Go benchmarks. Go's JIT-less compile model
  means there's no useful warmup beyond the first iteration; first-call
  allocations are amortised across the `b.N` loop count chosen by the
  testing harness.
