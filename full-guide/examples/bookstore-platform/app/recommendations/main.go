// Command recommendations is the Bookstore Platform v2 recommender wrapper.
// It exposes a per-tenant /v2/recommendations API and forwards predictions
// to the KServe InferenceService that serves the model from MLflow
// (ch.13.08). It also publishes each prediction to Kafka `ml.predictions`
// so Alibi-Detect can compute drift on a sliding window.
//
// Intentionally small (~150 lines): two HTTP endpoints, one KServe call,
// one Kafka write. The chapter calls out what is missing in production
// (request batching, embedding cache, A/B-test traffic split with a
// feature-flag SDK, etc.).
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
)

type config struct {
	port          string
	kservePredict string
	kafkaBrokers  []string
	kafkaTopic    string
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config{
		port:          envOr("PORT", "8080"),
		kservePredict: envOr("KSERVE_PREDICT_URL", "http://recommender-predictor.bookstore-platform-ml.svc.cluster.local/v1/models/recommender:predict"),
		kafkaBrokers:  strings.Split(envOr("KAFKA_BROKERS", "bookstore-platform-kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9092"), ","),
		kafkaTopic:    envOr("KAFKA_TOPIC_PREDICTIONS", "ml.predictions"),
	}

	w := &kafka.Writer{Addr: kafka.TCP(cfg.kafkaBrokers...), Topic: cfg.kafkaTopic, Balancer: &kafka.Hash{}}
	defer w.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(rw http.ResponseWriter, _ *http.Request) {
		_, _ = rw.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("GET /readyz", func(rw http.ResponseWriter, _ *http.Request) {
		_, _ = rw.Write([]byte(`{"status":"ready"}`))
	})
	mux.HandleFunc("POST /v2/recommendations", handleRecommend(cfg, w, log))

	srv := &http.Server{Addr: ":" + cfg.port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("recommendations listening", "addr", srv.Addr)
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

func handleRecommend(cfg config, w *kafka.Writer, log *slog.Logger) http.HandlerFunc {
	type req struct {
		UserID   string   `json:"user_id"`
		Features []float64 `json:"features"`
	}
	type resp struct {
		Tenant      string  `json:"tenant"`
		UserID      string  `json:"user_id"`
		Predictions []any   `json:"predictions"`
	}
	return func(rw http.ResponseWriter, r *http.Request) {
		tenant, err := tenantFromHeader(r.Header.Get("x-jwt-payload"))
		if err != nil {
			writeErr(rw, http.StatusUnauthorized, "tenant claim missing")
			return
		}
		var p req
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<14)).Decode(&p); err != nil {
			writeErr(rw, http.StatusBadRequest, "invalid body")
			return
		}
		// Forward to KServe in the v1 protocol shape: {"instances": [[...]]}.
		payload, _ := json.Marshal(map[string]any{"instances": [][]float64{p.Features}})
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		preq, _ := http.NewRequestWithContext(ctx, http.MethodPost, cfg.kservePredict, strings.NewReader(string(payload)))
		preq.Header.Set("Content-Type", "application/json")
		client := &http.Client{Timeout: 5 * time.Second}
		presp, err := client.Do(preq)
		if err != nil {
			log.Error("kserve call failed", "err", err)
			writeErr(rw, http.StatusBadGateway, "model backend unavailable")
			return
		}
		defer presp.Body.Close()
		body, _ := io.ReadAll(presp.Body)
		var parsed struct {
			Predictions []any `json:"predictions"`
		}
		_ = json.Unmarshal(body, &parsed)

		// Async-ish publish for drift detection. We do NOT block the
		// response on the publish — drift telemetry is best-effort.
		go func() {
			evt := map[string]any{
				"tenant":      tenant,
				"user_id":     p.UserID,
				"features":    p.Features,
				"predictions": parsed.Predictions,
				"at":          time.Now().UTC().Format(time.RFC3339Nano),
			}
			evtB, _ := json.Marshal(evt)
			ctx2, cancel2 := context.WithTimeout(context.Background(), 1*time.Second)
			defer cancel2()
			if err := w.WriteMessages(ctx2, kafka.Message{Key: []byte(tenant), Value: evtB}); err != nil {
				log.Warn("prediction publish failed", "err", err)
			}
		}()

		rw.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(rw).Encode(resp{Tenant: tenant, UserID: p.UserID, Predictions: parsed.Predictions})
	}
}

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
