// Command payments-worker is the Bookstore Platform v2 payments-worker stub.
// Runs a background polling loop (every 30s) that logs "polling for orders..."
// and exposes GET /healthz so Kubernetes liveness probes work.
// Introduced in ch.13-15 references; this stub makes those references
// resolve to real, buildable code. See README.md for what production
// would add.
//
// Intentionally small (~55 lines): stdlib only, JSON logger via log/slog,
// graceful shutdown on SIGTERM.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	port := envOr("PORT", "8080")
	interval := 30 * time.Second

	// Health endpoint so Kubernetes liveness probe works even though this
	// service has no customer-facing HTTP API.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Start HTTP server in background.
	errCh := make(chan error, 1)
	go func() {
		log.Info("payments-worker health endpoint listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	// Worker polling loop.
	log.Info("payments-worker started", "poll_interval", interval.String())
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case err := <-errCh:
			log.Error("health server failed", "err", err)
			os.Exit(1)
		case <-ctx.Done():
			log.Info("shutdown signal received")
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = srv.Shutdown(shutdownCtx)
			return
		case <-ticker.C:
			log.Info("polling for orders...")
			// Production: query outbox table or consume from Kafka topic
			// "order.created", call payments-gateway POST /charge.
		}
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
