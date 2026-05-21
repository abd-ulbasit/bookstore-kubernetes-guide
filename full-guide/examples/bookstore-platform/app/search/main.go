// Command search is the Bookstore Platform v2 search API. Wraps the
// in-cluster Meilisearch engine and exposes a per-tenant /v2/search
// endpoint. The tenant is read from the verified x-jwt-payload header
// (set by Istio's RequestAuthentication; see ch.13.04) — the binary
// trusts that header is base64 JSON whose `tenant` claim is the index
// suffix.
//
// Intentionally small (~150 lines): demonstrates the pattern (per-tenant
// search routing + JWT-claim plumbing) but is not a full search backend.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type config struct {
	port            string
	meiliBaseURL    string
	meiliMasterKey  string
	indexNamePrefix string
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config{
		port:            envOr("PORT", "8080"),
		meiliBaseURL:    envOr("MEILI_URL", "http://meilisearch.bookstore-platform-search.svc.cluster.local:7700"),
		meiliMasterKey:  os.Getenv("MEILI_MASTER_KEY"),
		indexNamePrefix: envOr("INDEX_PREFIX", "books-"),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"status":"ready"}`))
	})
	mux.HandleFunc("GET /v2/search", handleSearch(cfg, log))

	srv := &http.Server{
		Addr:              ":" + cfg.port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("search listening", "addr", srv.Addr)
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

func handleSearch(cfg config, log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenant, err := tenantFromHeader(r.Header.Get("x-jwt-payload"))
		if err != nil {
			writeErr(w, http.StatusUnauthorized, "tenant claim missing")
			return
		}
		q := strings.TrimSpace(r.URL.Query().Get("q"))
		if q == "" {
			writeErr(w, http.StatusBadRequest, "missing query parameter q")
			return
		}
		index := cfg.indexNamePrefix + tenant
		body, err := meiliSearch(r.Context(), cfg, index, q)
		if err != nil {
			log.Error("meilisearch call failed", "err", err, "index", index)
			writeErr(w, http.StatusBadGateway, "search backend unavailable")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("x-tenant", tenant)
		_, _ = w.Write(body)
	}
}

func meiliSearch(ctx context.Context, cfg config, index, q string) ([]byte, error) {
	endpoint, err := url.Parse(cfg.meiliBaseURL + "/indexes/" + url.PathEscape(index) + "/search")
	if err != nil {
		return nil, err
	}
	payload, _ := json.Marshal(map[string]any{"q": q, "limit": 20})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), strings.NewReader(string(payload)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if cfg.meiliMasterKey != "" {
		req.Header.Set("Authorization", "Bearer "+cfg.meiliMasterKey)
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return nil, errors.New("meilisearch: " + resp.Status + " " + string(body))
	}
	return io.ReadAll(resp.Body)
}

// tenantFromHeader decodes the base64 JWT payload header and pulls the
// `tenant` claim. The header is written by the gateway after the JWT
// passes RequestAuthentication; downstream services trust it (ch.13.04
// §Mesh validates...).
func tenantFromHeader(payloadB64 string) (string, error) {
	if payloadB64 == "" {
		return "", errors.New("no jwt header")
	}
	raw, err := base64.RawStdEncoding.DecodeString(payloadB64)
	if err != nil {
		raw, err = base64.StdEncoding.DecodeString(payloadB64)
		if err != nil {
			return "", err
		}
	}
	var claims struct {
		Tenant string `json:"tenant"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil {
		return "", err
	}
	if claims.Tenant == "" {
		return "", errors.New("tenant claim empty")
	}
	return claims.Tenant, nil
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
