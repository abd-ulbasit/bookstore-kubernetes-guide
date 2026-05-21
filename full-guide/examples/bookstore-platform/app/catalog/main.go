// Command catalog is the Bookstore Platform v2 catalog stub.
// Exposes GET / (hardcoded book list) and GET /healthz.
// Introduced in ch.13-15 references; this stub makes those references
// resolve to real, buildable code. See README.md for what production
// would add.
//
// Intentionally small (~50 lines): stdlib only, JSON logger via log/slog,
// graceful shutdown on SIGTERM.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type book struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Author string `json:"author"`
	ISBN   string `json:"isbn"`
}

var catalog = []book{
	{ID: "1", Title: "The Go Programming Language", Author: "Alan A. A. Donovan", ISBN: "978-0134190440"},
	{ID: "2", Title: "Kubernetes in Action", Author: "Marko Lukša", ISBN: "978-1617293726"},
	{ID: "3", Title: "Designing Data-Intensive Applications", Author: "Martin Kleppmann", ISBN: "978-1449373320"},
}

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
		_ = json.NewEncoder(w).Encode(map[string]any{"service": "catalog", "books": catalog})
	})

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("catalog listening", "addr", srv.Addr)
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

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
