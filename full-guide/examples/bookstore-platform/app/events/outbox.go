package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"log/slog"
	"os"
	"time"

	"github.com/segmentio/kafka-go"
)

// runOutbox polls the outbox table every two seconds and publishes each batch
// to orders.placed. Replicas run this loop side by side; publishOutboxBatch
// makes them share the rows instead of publishing the same ones.
func runOutbox(ctx context.Context, log *slog.Logger, brokers []string, tlsCfg *tls.Config) {
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
	w := kafkaWriter(brokers, topic, tlsCfg)
	defer w.Close()
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		n, err := publishOutboxBatch(ctx, db, w)
		if err != nil {
			log.Warn("outbox batch failed; its rows stay unpublished", "err", err)
			continue
		}
		if n > 0 {
			log.Info("outbox batch published", "count", n)
		}
	}
}

// publishOutboxBatch publishes up to 100 unpublished rows in one transaction.
// FOR UPDATE SKIP LOCKED makes a row that another publisher holds invisible
// to this one, so no waiting and no double claim. A failure rolls the batch
// back, so its rows are published again; consumers dedupe on event_id.
func publishOutboxBatch(ctx context.Context, db *sql.DB, w *kafka.Writer) (int, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	rows, err := tx.QueryContext(ctx, `SELECT event_id, payload FROM bookstore_platform.outbox WHERE published_at IS NULL ORDER BY created_at LIMIT 100 FOR UPDATE SKIP LOCKED`)
	if err != nil {
		return 0, err
	}
	type outboxRow struct {
		eventID string
		payload []byte
	}
	var batch []outboxRow
	for rows.Next() {
		var r outboxRow
		if err := rows.Scan(&r.eventID, &r.payload); err != nil {
			_ = rows.Close()
			return 0, err
		}
		batch = append(batch, r)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return 0, err
	}
	_ = rows.Close()

	for _, r := range batch {
		if err := w.WriteMessages(ctx, kafka.Message{Key: []byte(r.eventID), Value: r.payload}); err != nil {
			return 0, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE bookstore_platform.outbox SET published_at = now() WHERE event_id = $1`, r.eventID); err != nil {
			return 0, err
		}
	}
	return len(batch), tx.Commit()
}
