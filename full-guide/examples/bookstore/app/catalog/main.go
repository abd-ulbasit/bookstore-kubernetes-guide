// Command catalog is the Bookstore catalog API.
//
// It serves the book listing. If DB_DSN is set it reads from the Postgres
// "books" table; otherwise it serves an in-memory sample. If REDIS_ADDR is set
// the listing is cached in Redis. It exposes Prometheus metrics and health
// endpoints and shuts down gracefully on SIGTERM.
//
// This service is intentionally tiny: it is a vehicle for Kubernetes concepts,
// not a production e-commerce backend.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/v9"
)

// Book is a single catalog entry.
type Book struct {
	ID     int     `json:"id"`
	Title  string  `json:"title"`
	Author string  `json:"author"`
	Price  float64 `json:"price"`
}

var sampleBooks = []Book{
	{ID: 1, Title: "The Go Programming Language", Author: "Donovan & Kernighan", Price: 39.99},
	{ID: 2, Title: "Kubernetes in Action", Author: "Marko Lukša", Price: 49.99},
	{ID: 3, Title: "Kubernetes Patterns", Author: "Ibryam & Huß", Price: 44.99},
	{ID: 4, Title: "Production Kubernetes", Author: "Rosso et al.", Price: 54.99},
}

const cacheKey = "catalog:books"

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "Total HTTP requests processed, partitioned by handler and status.",
	}, []string{"handler", "code"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request latency in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"handler"})
)

// app holds the process dependencies. Any of them may be nil/absent.
type app struct {
	log *slog.Logger
	db  *pgxpool.Pool
	rdb *redis.Client
}

func main() {
	log := newLogger(env("LOG_LEVEL", "info"))

	a := &app{log: log}
	ctx := context.Background()

	if dsn := os.Getenv("DB_DSN"); dsn != "" {
		pool, err := pgxpool.New(ctx, dsn)
		if err != nil {
			log.Error("connect postgres", "err", err)
			os.Exit(1)
		}
		a.db = pool
		defer pool.Close()
		log.Info("postgres configured")
	} else {
		log.Info("DB_DSN unset; serving in-memory sample books")
	}

	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		a.rdb = redis.NewClient(&redis.Options{Addr: addr})
		defer func() { _ = a.rdb.Close() }()
		log.Info("redis cache configured", "addr", addr)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.instrument("healthz", a.handleHealthz))
	mux.HandleFunc("GET /readyz", a.instrument("readyz", a.handleReadyz))
	mux.HandleFunc("GET /books", a.instrument("books", a.handleBooks))
	mux.Handle("GET /metrics", promhttp.Handler()) // not instrumented: Prometheus tracks its own scrapes

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Run the server and block until a termination signal arrives.
	errCh := make(chan error, 1)
	go func() {
		log.Info("catalog listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errCh:
		log.Error("server failed", "err", err)
		os.Exit(1)
	case sig := <-stop:
		log.Info("shutdown signal received", "signal", sig.String())
	}

	// Graceful shutdown: stop accepting new connections, drain in-flight.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	log.Info("shutdown complete")
}

// instrument wraps a handler with request counting and latency observation.
func (a *app) instrument(name string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)
		httpDuration.WithLabelValues(name).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(name, strconv.Itoa(rec.status)).Inc()
	}
}

func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReadyz reports ready only when configured backends are reachable.
func (a *app) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if a.db != nil {
		if err := a.db.Ping(ctx); err != nil {
			a.log.Warn("readyz: postgres not ready", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db unavailable"})
			return
		}
	}
	if a.rdb != nil {
		if err := a.rdb.Ping(ctx).Err(); err != nil {
			a.log.Warn("readyz: redis not ready", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "cache unavailable"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *app) handleBooks(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	if a.rdb != nil {
		if cached, err := a.rdb.Get(ctx, cacheKey).Bytes(); err == nil {
			w.Header().Set("X-Cache", "HIT")
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(cached)
			return
		}
	}

	books, err := a.loadBooks(ctx)
	if err != nil {
		a.log.Error("load books", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cannot load catalog"})
		return
	}

	if books == nil {
		books = []Book{} // ensure an empty result serializes as [] not null
	}
	body, _ := json.Marshal(books)
	if a.rdb != nil {
		if err := a.rdb.Set(ctx, cacheKey, body, 30*time.Second).Err(); err != nil {
			a.log.Warn("cache write failed", "err", err)
		}
	}
	w.Header().Set("X-Cache", "MISS")
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(body)
}

// loadBooks reads from Postgres when configured, else returns the sample set.
func (a *app) loadBooks(ctx context.Context) ([]Book, error) {
	if a.db == nil {
		return sampleBooks, nil
	}
	rows, err := a.db.Query(ctx, `SELECT id, title, author, price FROM books ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var books []Book
	for rows.Next() {
		var b Book
		if err := rows.Scan(&b.ID, &b.Title, &b.Author, &b.Price); err != nil {
			return nil, err
		}
		books = append(books, b)
	}
	return books, rows.Err()
}

// --- small helpers -------------------------------------------------------

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(level)); err != nil {
		lvl = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}))
}
