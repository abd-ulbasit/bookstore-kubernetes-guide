// Command events is the Bookstore Platform v2 Kafka dispatcher. One
// binary, three modes selected by EVENTS_MODE: "outbox" (publish the
// outbox table to orders.placed), "payments-worker" (consume orders.placed,
// charge once through payments-gateway, publish the outcome), and
// "drift-relay" (consume ml.drift; ch.13.08 smoke test). KAFKA_TLS_DIR names
// the mounted KafkaUser secret; when it is set, every Kafka connection uses
// TLS and that client certificate.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	mode := envOr("EVENTS_MODE", "outbox")
	port := envOr("PORT", "8080")
	brokers := strings.Split(envOr("KAFKA_BROKERS", "bookstore-platform-kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9093"), ",")
	tlsCfg, err := kafkaTLSFromEnv()
	if err != nil {
		log.Error("kafka tls", "err", err)
		os.Exit(1)
	}

	// Health server (every mode runs this; lets the Pod readiness probe
	// succeed independently of the worker loop).
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ok"}`)) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ready"}`)) })
	srv := &http.Server{Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("health server failed", "err", err)
			stop()
		}
	}()

	switch mode {
	case "outbox":
		runOutbox(ctx, log, brokers, tlsCfg)
	case "payments-worker":
		runPaymentsWorker(ctx, log, brokers, tlsCfg)
	case "drift-relay":
		runDriftRelay(ctx, log, brokers, tlsCfg)
	default:
		log.Error("unknown EVENTS_MODE", "mode", mode)
		stop()
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	log.Info("shutdown complete")
}

// kafkaWriter returns a writer that waits for every in-sync replica
// (acks=all). A nil tlsCfg means plaintext.
func kafkaWriter(brokers []string, topic string, tlsCfg *tls.Config) *kafka.Writer {
	return &kafka.Writer{
		Addr: kafka.TCP(brokers...), Topic: topic, Balancer: &kafka.Hash{},
		RequiredAcks: kafka.RequireAll, Transport: &kafka.Transport{TLS: tlsCfg},
	}
}

// runDriftRelay consumes ml.drift and logs each event: ch.13.08's
// smoke test to confirm drift events are flowing.
func runDriftRelay(ctx context.Context, log *slog.Logger, brokers []string, tlsCfg *tls.Config) {
	topic := envOr("KAFKA_TOPIC_DRIFT", "ml.drift")
	group := envOr("KAFKA_CONSUMER_GROUP", "drift-relay")
	r := kafka.NewReader(kafka.ReaderConfig{
		Brokers: brokers, Topic: topic, GroupID: group,
		Dialer: &kafka.Dialer{Timeout: 10 * time.Second, TLS: tlsCfg},
	})
	defer r.Close()
	for {
		msg, err := r.ReadMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Warn("kafka read failed", "err", err)
			continue
		}
		log.Info("drift event", "key", string(msg.Key), "value", string(msg.Value))
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
