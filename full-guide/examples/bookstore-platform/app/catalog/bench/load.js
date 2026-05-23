// k6 end-to-end load test for the catalog service.
//
// Run against a local service:
//     # one terminal: start the service
//     DB_DSN=postgres://catalog:catalog@localhost:5432/catalog?sslmode=disable \
//         go run .
//     # another: drive load
//     k6 run --summary-trend-stats="avg,min,med,max,p(50),p(95),p(99),p(99.9)" \
//         bench/load.js
//
// Two scenarios run concurrently:
//   - "reads"  — constant 1000 RPS of GET /books/{id}, hot in-memory path
//   - "writes" — ramp up to 100 RPS of POST /books, exercises validate+insert
//
// Thresholds (the build/CI fails the run if these aren't met):
//   - 95% of read latencies < 50ms
//   - 99% of read latencies < 100ms
//   - failure rate < 1%
//
// Adjust `BASE_URL` if you're running the service on a different host/port.

import http from 'k6/http';
import { check } from 'k6';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  scenarios: {
    reads: {
      executor: 'constant-arrival-rate',
      exec: 'readBooks',
      rate: 1000,
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 50,
      maxVUs: 200,
    },
    writes: {
      executor: 'ramping-arrival-rate',
      exec: 'createBook',
      startRate: 10,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 100,
      stages: [
        { target: 100, duration: '10s' },
        { target: 100, duration: '15s' },
        { target: 0,   duration: '5s'  },
      ],
    },
  },
  thresholds: {
    'http_req_duration{scenario:reads}': ['p(95)<50', 'p(99)<100'],
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],
  },
};

// Read scenario: hot-path GETs against seeded book IDs.
export function readBooks() {
  const id = String(randomIntBetween(1, 3));
  const r = http.get(`${BASE_URL}/books/${id}`);
  check(r, { 'status 200': (x) => x.status === 200 });
}

// Write scenario: every POST uses a unique id so duplicates don't skew
// the latency distribution toward conflicts.
export function createBook() {
  const id = `vu-${__VU}-iter-${__ITER}-${Date.now()}`;
  const body = JSON.stringify({
    id,
    title: 'Load Test Book',
    author: 'k6',
    isbn: '9781617293726',
  });
  const r = http.post(`${BASE_URL}/books`, body, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(r, { 'status 201': (x) => x.status === 201 });
}
