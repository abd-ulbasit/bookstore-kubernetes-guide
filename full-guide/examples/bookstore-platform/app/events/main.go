// Command events is the Bookstore Platform v2 Kafka dispatcher. One
// binary, three modes selected by EVENTS_MODE: "outbox" (publish the
// outbox table to orders.placed), "payments-worker" (consume
// orders.placed -> POST /charge -> publish payments.completed), and
// "drift-relay" (consume ml.drift; ch.13.08 smoke test).
// Intentionally small (<=200 lines including all three modes).
package main

import (
	"context"
	"database/sql"
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

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/segmentio/kafka-go"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	mode := envOr("EVENTS_MODE", "outbox")
	port := envOr("PORT", "8080")
	brokers := strings.Split(envOr("KAFKA_BROKERS", "bookstore-platform-kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9092"), ",")

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
		runOutbox(ctx, log, brokers)
	case "payments-worker":
		runPaymentsWorker(ctx, log, brokers)
	case "drift-relay":
		runDriftRelay(ctx, log, brokers)
	default:
		log.Error("unknown EVENTS_MODE", "mode", mode)
		stop()
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	log.Info("shutdown complete")
}

// runOutbox polls the outbox table for unpublished rows and publishes
// each to orders.placed. At-least-once delivery (acks=all); consumer
// dedupes on event_id.
func runOutbox(ctx context.Context, log *slog.Logger, brokers []string) {
	dsn := os.Getenv("DB_DSN")
	topic := envOr("KAFKA_TOPIC_ORDERS_PLACED", "orders.placed")
	if dsn == "" {
		log.Info("DB_DSN unset; outbox loop idling")
		<-ctx.Done()
		return
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		log.Error("db open", "err", err)
		return
	}
	defer db.Close()
	w := &kafka.Writer{Addr: kafka.TCP(brokers...), Topic: topic, Balancer: &kafka.Hash{}, RequiredAcks: kafka.RequireAll}
	defer w.Close()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		rows, err := db.QueryContext(ctx, `SELECT event_id, payload FROM bookstore_platform.outbox WHERE published_at IS NULL ORDER BY created_at LIMIT 100`)
		if err != nil {
			log.Warn("outbox poll failed", "err", err)
			continue
		}
		published := 0
		for rows.Next() {
			var eventID string
			var payload []byte
			if err := rows.Scan(&eventID, &payload); err != nil {
				continue
			}
			if err := w.WriteMessages(ctx, kafka.Message{Key: []byte(eventID), Value: payload}); err != nil {
				log.Warn("publish failed", "err", err)
				continue
			}
			if _, err := db.ExecContext(ctx, `UPDATE bookstore_platform.outbox SET published_at = now() WHERE event_id = $1`, eventID); err != nil {
				log.Warn("mark published failed", "err", err)
				continue
			}
			published++
		}
		_ = rows.Close()
		if published > 0 {
			log.Info("outbox batch published", "count", published)
		}
	}
}

// runPaymentsWorker consumes orders.placed; for each event calls
// payments-gateway /charge; on 200 publishes payments.completed and
// commits the offset.
func runPaymentsWorker(ctx context.Context, log *slog.Logger, brokers []string) {
	topicIn := envOr("KAFKA_TOPIC_ORDERS_PLACED", "orders.placed")
	topicOut := envOr("KAFKA_TOPIC_PAYMENTS_COMPLETED", "payments.completed")
	group := envOr("KAFKA_CONSUMER_GROUP", "payments-worker")
	gatewayURL := envOr("PAYMENTS_GATEWAY_URL", "http://payments-gateway.bookstore-platform-payments.svc.cluster.local:8080")
	r := kafka.NewReader(kafka.ReaderConfig{Brokers: brokers, Topic: topicIn, GroupID: group, MinBytes: 1, MaxBytes: 1 << 20})
	defer r.Close()
	w := &kafka.Writer{Addr: kafka.TCP(brokers...), Topic: topicOut, Balancer: &kafka.Hash{}, RequiredAcks: kafka.RequireAll}
	defer w.Close()
	client := &http.Client{Timeout: 10 * time.Second}
	for {
		msg, err := r.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Warn("kafka fetch failed", "err", err)
			continue
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, gatewayURL+"/charge", strings.NewReader(string(msg.Value)))
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			log.Warn("gateway call failed; will retry", "err", err, "event_id", string(msg.Key))
			continue // do NOT commit; Kafka will redeliver
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode >= 500 {
			log.Warn("gateway 5xx; will retry", "status", resp.StatusCode, "event_id", string(msg.Key))
			continue
		}
		// Even on 4xx (e.g. invalid amount) we COMMIT — retrying a
		// permanent error is a poison-message loop; the dead-letter
		// pattern handles this in production.
		out := map[string]any{"event_id": string(msg.Key), "result": json.RawMessage(body), "status": resp.StatusCode}
		outB, _ := json.Marshal(out)
		_ = w.WriteMessages(ctx, kafka.Message{Key: msg.Key, Value: outB})
		if err := r.CommitMessages(ctx, msg); err != nil {
			log.Warn("commit failed", "err", err)
		}
	}
}

// runDriftRelay consumes ml.drift and logs each event — ch.13.08's
// smoke test to confirm drift events are flowing.
func runDriftRelay(ctx context.Context, log *slog.Logger, brokers []string) {
	topic := envOr("KAFKA_TOPIC_DRIFT", "ml.drift")
	group := envOr("KAFKA_CONSUMER_GROUP", "drift-relay")
	r := kafka.NewReader(kafka.ReaderConfig{Brokers: brokers, Topic: topic, GroupID: group})
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
