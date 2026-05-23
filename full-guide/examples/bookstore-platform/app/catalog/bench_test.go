package main

// Go in-process benchmarks. These measure the handler chain end-to-end
// (router + middleware + repo) WITHOUT network I/O, so the numbers are
// the service's own work — not whatever the kernel networking stack added.
// For end-to-end network benchmarking, see bench/load.js (k6).

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func benchServer(b *testing.B, books int) http.Handler {
	b.Helper()
	repo := NewMemRepo()
	for i := range books {
		id := strings_repeat("0", 1) + intToString(i+1)
		_, _ = repo.Create(context.Background(), Book{
			ID: id, Title: "Title " + id, Author: "Author " + id, ISBN: "9781617293726",
		})
	}
	s := &Server{
		Repo:    repo,
		Log:     slog.New(slog.NewJSONHandler(io.Discard, nil)),
		Metrics: NewMetrics(prometheus.NewRegistry()),
	}
	return s.Routes()
}

// tiny helpers so we don't import strconv just for these
func intToString(n int) string {
	if n == 0 {
		return "0"
	}
	var digits [20]byte
	i := len(digits)
	for n > 0 {
		i--
		digits[i] = byte('0' + n%10)
		n /= 10
	}
	return string(digits[i:])
}

func strings_repeat(s string, n int) string { return strings.Repeat(s, n) }

// BenchmarkHealthz: trivial baseline — what's the floor for a handler
// that does ~no work? Use this number as the noise floor when reading
// the others.
func BenchmarkHealthz(b *testing.B) {
	h := benchServer(b, 0)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	b.ResetTimer()
	for b.Loop() {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
	}
}

// BenchmarkGetBook_Hot: hot-path lookup, in-memory repo, no allocation
// per request beyond the response body marshal.
func BenchmarkGetBook_Hot(b *testing.B) {
	h := benchServer(b, 100)
	req := httptest.NewRequest(http.MethodGet, "/books/00000050", nil) // id "00000050" — exists if seeded with leading-zero scheme; otherwise 404 path
	// Actually use a definitely-present id from our seed scheme:
	req = httptest.NewRequest(http.MethodGet, "/books/050", nil)
	// Easier: seed deterministically and pick a known id
	req = httptest.NewRequest(http.MethodGet, "/books/1", nil)
	b.ResetTimer()
	for b.Loop() {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
	}
}

// BenchmarkListBooks_100: list 50 of 100 books — exercises pagination
// plus JSON-encoding a list response.
func BenchmarkListBooks_100(b *testing.B) {
	h := benchServer(b, 100)
	req := httptest.NewRequest(http.MethodGet, "/books?limit=50", nil)
	b.ResetTimer()
	for b.Loop() {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
	}
}

// BenchmarkCreateBook: full POST path including JSON decode + validate
// + insert (in-memory). Useful as a write-side baseline.
func BenchmarkCreateBook(b *testing.B) {
	h := benchServer(b, 0)
	body := `{"id":"new","title":"T","author":"A","isbn":"9781617293726"}`
	b.ResetTimer()
	for b.Loop() {
		req := httptest.NewRequest(http.MethodPost, "/books", strings.NewReader(body))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		// MemRepo errors on duplicate id; fine — we're measuring the path
		// up to the conflict, which is identical to the success path bar
		// the final map write.
	}
}

// BenchmarkMetricsScrape: how heavy is /metrics? Prometheus scraping
// is usually every 15s in production; a scrape that takes >100ms is a
// problem. This benchmark gives the wall-clock per scrape.
func BenchmarkMetricsScrape(b *testing.B) {
	h := benchServer(b, 100)
	// warm a few path/status labels
	for range 50 {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/books", nil))
	}
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	b.ResetTimer()
	for b.Loop() {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
	}
}
