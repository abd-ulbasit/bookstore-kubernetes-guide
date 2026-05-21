// Command orders is the Bookstore orders API.
//
// POST /orders validates a JSON body {book_id, qty}, writes an "orders" row to
// Postgres when DB_DSN is set (otherwise it logs the order), and publishes an
// order event to the RabbitMQ "orders" queue when AMQP_URL is set. It exposes
// Prometheus metrics and health endpoints and shuts down gracefully on SIGTERM.
//
// Intentionally tiny: a vehicle for Kubernetes concepts, not a real checkout.
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
	amqp "github.com/rabbitmq/amqp091-go"
)

const queueName = "orders"

// orderRequest is the accepted POST /orders body.
type orderRequest struct {
	BookID int `json:"book_id"`
	Qty    int `json:"qty"`
}

func (o orderRequest) valid() bool { return o.BookID > 0 && o.Qty > 0 }

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

	ordersPlaced = promauto.NewCounter(prometheus.CounterOpts{
		Name: "orders_placed_total",
		Help: "Total orders accepted.",
	})
)

type app struct {
	log     *slog.Logger
	db      *pgxpool.Pool
	amqpURL string
}

func main() {
	log := newLogger(env("LOG_LEVEL", "info"))
	a := &app{log: log, amqpURL: os.Getenv("AMQP_URL")}
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
		log.Info("DB_DSN unset; orders will be logged only")
	}
	if a.amqpURL == "" {
		log.Info("AMQP_URL unset; order events will not be published")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /orders", a.instrument("orders", a.handleCreateOrder))
	mux.HandleFunc("GET /healthz", a.instrument("healthz", a.handleHealthz))
	mux.HandleFunc("GET /readyz", a.instrument("readyz", a.handleReadyz))
	mux.Handle("GET /metrics", promhttp.Handler()) // not instrumented: Prometheus tracks its own scrapes

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("orders listening", "addr", srv.Addr)
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

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	log.Info("shutdown complete")
}

func (a *app) instrument(name string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		h(rec, r)
		httpDuration.WithLabelValues(name).Observe(time.Since(start).Seconds())
		httpRequests.WithLabelValues(name, strconv.Itoa(rec.status)).Inc()
	}
}

func (a *app) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req orderRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	if !req.valid() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "book_id and qty must be > 0"})
		return
	}

	ctx := r.Context()
	orderID, err := a.persist(ctx, req)
	if err != nil {
		a.log.Error("persist order", "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cannot place order"})
		return
	}

	if err := a.publish(ctx, orderID, req); err != nil {
		// The order is already durable; a publish failure is logged, not fatal.
		a.log.Warn("publish order event failed", "order_id", orderID, "err", err)
	}

	ordersPlaced.Inc()
	a.log.Info("order placed", "order_id", orderID, "book_id", req.BookID, "qty", req.Qty)
	writeJSON(w, http.StatusCreated, map[string]any{"order_id": orderID, "status": "accepted"})
}

// persist writes the order to Postgres if configured; otherwise it logs and
// returns a synthetic id so the demo path still works without a database.
func (a *app) persist(ctx context.Context, req orderRequest) (int64, error) {
	if a.db == nil {
		a.log.Info("DB_DSN unset; not persisting", "book_id", req.BookID, "qty", req.Qty)
		return time.Now().UnixNano(), nil
	}
	var id int64
	err := a.db.QueryRow(ctx,
		`INSERT INTO orders (book_id, qty, created_at) VALUES ($1, $2, now()) RETURNING id`,
		req.BookID, req.Qty,
	).Scan(&id)
	return id, err
}

// publish sends an order event to RabbitMQ if AMQP_URL is set.
func (a *app) publish(ctx context.Context, orderID int64, req orderRequest) error {
	if a.amqpURL == "" {
		return nil
	}
	// Simplified: we dial a fresh AMQP connection per request. Production code
	// reuses a long-lived connection with reconnect logic.
	conn, err := amqp.Dial(a.amqpURL)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	defer func() { _ = ch.Close() }()

	if _, err := ch.QueueDeclare(queueName, true, false, false, false, nil); err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{
		"order_id": orderID, "book_id": req.BookID, "qty": req.Qty,
	})
	return ch.PublishWithContext(ctx, "", queueName, false, false, amqp.Publishing{
		ContentType:  "application/json",
		DeliveryMode: amqp.Persistent,
		Body:         body,
	})
}

func (a *app) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *app) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if a.db != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := a.db.Ping(ctx); err != nil {
			a.log.Warn("readyz: postgres not ready", "err", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db unavailable"})
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
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
