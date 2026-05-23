package main

import (
	"context"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// Metrics bundles the Prometheus collectors for the service plus the
// registry they were registered against. Handler() returns a /metrics
// handler scoped to this same registry, so a test with an isolated
// registry sees its own metrics (and a production main with the default
// registry sees the Go runtime + process collectors for free).
type Metrics struct {
	registry        *prometheus.Registry
	requestsTotal   *prometheus.CounterVec
	requestDuration *prometheus.HistogramVec
}

// NewMetrics registers the two custom collectors PLUS the standard Go
// runtime + process collectors against the given registry, so a single
// /metrics endpoint exposes everything a Prometheus scraper expects.
// Buckets follow Prometheus' default-but-shifted set so the histogram's
// resolution lands where HTTP service P50/P95/P99 typically live (1ms..2s).
func NewMetrics(registry *prometheus.Registry) *Metrics {
	factory := promauto.With(registry)
	registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	return &Metrics{
		registry: registry,
		requestsTotal: factory.NewCounterVec(
			prometheus.CounterOpts{
				Name: "catalog_http_requests_total",
				Help: "HTTP requests, labelled by method, path template, and status class.",
			},
			[]string{"method", "path", "status"},
		),
		requestDuration: factory.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "catalog_http_request_duration_seconds",
				Help:    "HTTP request latency in seconds.",
				Buckets: []float64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
			},
			[]string{"method", "path"},
		),
	}
}

// Observe records one request's metrics. Called from middleware.
func (m *Metrics) Observe(method, path string, status int, dur time.Duration) {
	m.requestsTotal.WithLabelValues(method, path, statusClass(status)).Inc()
	m.requestDuration.WithLabelValues(method, path).Observe(dur.Seconds())
}

// Handler returns the http.Handler that serves the /metrics endpoint
// from this Metrics' own registry.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.registry, promhttp.HandlerOpts{Registry: m.registry})
}

// statusClass maps 200→"2xx", 404→"4xx", etc. Keeps label cardinality
// bounded; per-status-code labels explode the time series for no upside.
func statusClass(code int) string {
	switch {
	case code < 200:
		return "1xx"
	case code < 300:
		return "2xx"
	case code < 400:
		return "3xx"
	case code < 500:
		return "4xx"
	default:
		return "5xx"
	}
}

// --- tiny context shim so handlers.go can avoid an extra import ---

type contextLike = context.Context

func contextWithTimeoutImpl(parent context.Context, d time.Duration) (context.Context, func()) {
	return context.WithTimeout(parent, d)
}
