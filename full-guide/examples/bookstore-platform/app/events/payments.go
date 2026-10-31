package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/segmentio/kafka-go"
)

// runPaymentsWorker consumes orders.placed and charges each order once. An
// offset is committed only after the outcome is out: a 2xx or 4xx answer from
// the gateway is final, while a 5xx, a transport error or a failed write is
// retried in place. The partition waits rather than skipping a charge.
func runPaymentsWorker(ctx context.Context, log *slog.Logger, brokers []string, tlsCfg *tls.Config) {
	dsn := os.Getenv("DB_DSN")
	if dsn == "" {
		log.Error("DB_DSN unset; the worker needs its payments table")
		return
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		log.Error("db open", "err", err)
		return
	}
	defer db.Close()
	gatewayURL := envOr("PAYMENTS_GATEWAY_URL", "http://payments-gateway.bookstore-platform-payments.svc.cluster.local:8080")
	r := kafka.NewReader(kafka.ReaderConfig{
		Brokers: brokers, Topic: envOr("KAFKA_TOPIC_ORDERS_PLACED", "orders.placed"),
		GroupID:  envOr("KAFKA_CONSUMER_GROUP", "payments-worker"),
		MinBytes: 1, MaxBytes: 1 << 20,
		Dialer: &kafka.Dialer{Timeout: 10 * time.Second, TLS: tlsCfg},
	})
	defer r.Close()
	completed := kafkaWriter(brokers, envOr("KAFKA_TOPIC_PAYMENTS_COMPLETED", "payments.completed"), tlsCfg)
	defer completed.Close()
	failed := kafkaWriter(brokers, envOr("KAFKA_TOPIC_PAYMENTS_FAILED", "payments.failed"), tlsCfg)
	defer failed.Close()
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
		eventID := string(msg.Key)
		var status int
		var body []byte
		err = untilDone(ctx, log, "charge", func() error {
			var cerr error
			status, body, cerr = chargeOnce(ctx, client, db, gatewayURL, eventID, msg.Value)
			return cerr
		})
		if err != nil {
			return
		}
		out, _ := json.Marshal(map[string]any{"event_id": eventID, "status": status, "result": json.RawMessage(body)})
		topic := completed
		if status >= 400 {
			topic = failed
		}
		err = untilDone(ctx, log, "publish outcome", func() error {
			return topic.WriteMessages(ctx, kafka.Message{Key: msg.Key, Value: out})
		})
		if err != nil {
			return
		}
		if err := r.CommitMessages(ctx, msg); err != nil {
			log.Warn("commit failed", "err", err)
		}
	}
}

// chargeOnce asks the gateway to charge one order event and returns the
// gateway's status and body. The payments table is the replay guard: a row
// for the event means an earlier attempt already charged, so the stored
// payment intent is returned and Stripe is not called. Stripe's
// Idempotency-Key only covers 24 hours, so the table covers older replays.
func chargeOnce(ctx context.Context, client *http.Client, db *sql.DB, gatewayURL, eventID string, payload []byte) (int, []byte, error) {
	var prior string
	err := db.QueryRowContext(ctx, `SELECT payment_intent_id FROM bookstore_platform.payments WHERE event_id = $1`, eventID).Scan(&prior)
	if err == nil {
		replay, _ := json.Marshal(map[string]string{"payment_intent_id": prior, "status": "replayed"})
		return http.StatusOK, replay, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, gatewayURL+"/charge", bytes.NewReader(payload))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return 0, nil, err
	}
	if resp.StatusCode >= 500 {
		return 0, nil, fmt.Errorf("gateway answered %d", resp.StatusCode)
	}
	if resp.StatusCode >= 400 {
		return resp.StatusCode, body, nil
	}

	var pi struct {
		PaymentIntentID string `json:"payment_intent_id"`
		Status          string `json:"status"`
	}
	if err := json.Unmarshal(body, &pi); err != nil || pi.PaymentIntentID == "" {
		return 0, nil, errors.New("gateway reply names no payment intent")
	}
	_, err = db.ExecContext(ctx, `INSERT INTO bookstore_platform.payments (event_id, payment_intent_id, status) VALUES ($1, $2, $3) ON CONFLICT (event_id) DO NOTHING`, eventID, pi.PaymentIntentID, pi.Status)
	if err != nil {
		return 0, nil, err
	}
	return resp.StatusCode, body, nil
}

// untilDone calls fn until it returns nil or ctx ends. The pause between tries
// doubles from one second up to 30 seconds.
func untilDone(ctx context.Context, log *slog.Logger, what string, fn func() error) error {
	pause := time.Second
	for {
		err := fn()
		if err == nil {
			return nil
		}
		log.Warn(what+" failed; retrying", "err", err, "pause", pause.String())
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pause):
		}
		pause = min(2*pause, 30*time.Second)
	}
}
