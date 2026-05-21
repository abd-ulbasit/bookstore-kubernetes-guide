// Command orders is the Bookstore Platform v2 orders stub.
// Exposes POST /orders (echoes the body as the order) and GET /healthz.
// Introduced in ch.13-15 references; this stub makes those references
// resolve to real, buildable code. See README.md for what production
// would add.
//
// Intentionally small (~55 lines): stdlib only, JSON logger via log/slog,
// graceful shutdown on SIGTERM.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
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

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"service":"orders","endpoints":["POST /orders","GET /healthz"]}`))
	})
	mux.HandleFunc("POST /orders", handleCreateOrder(log))

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("orders listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		log.Error("server failed", "err", err)
		os.Exit(1)
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

// handleCreateOrder reads the request body and echoes it back as the created
// order, adding a stub order_id and status. In production this would persist
// to a database and publish an event to Kafka.
func handleCreateOrder(log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "failed to read body")
			return
		}
		var order map[string]any
		if len(body) > 0 {
			if err := json.Unmarshal(body, &order); err != nil {
				writeErr(w, http.StatusBadRequest, "invalid JSON body")
				return
			}
		} else {
			order = map[string]any{}
		}
		order["order_id"] = "ord-stub-001"
		order["status"] = "accepted"
		log.Info("order received (stub)", "order_id", order["order_id"])
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(order)
	}
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
