// Command payments-worker is the Bookstore background payment consumer.
//
// When AMQP_URL is set it consumes the RabbitMQ "orders" queue and "processes"
// a payment for each message (here: logs it and acks). When AMQP_URL is unset
// it idles, logging a heartbeat every 30s so the Pod is observably alive. It
// exposes /healthz and Prometheus /metrics on PORT and exits cleanly on
// SIGTERM.
//
// Intentionally tiny: a vehicle for the worker / KEDA-scaling concepts.
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

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	amqp "github.com/rabbitmq/amqp091-go"
)

const queueName = "orders"

var paymentsProcessed = promauto.NewCounter(prometheus.CounterOpts{
	Name: "payments_processed_total",
	Help: "Total payments processed by the worker.",
})

func main() {
	log := newLogger(env("LOG_LEVEL", "info"))

	// Health/metrics server runs for the whole process lifetime.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.Handle("GET /metrics", promhttp.Handler())
	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srvErr := make(chan error, 1)
	go func() {
		log.Info("payments-worker health server listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			srvErr <- err
		}
	}()

	// Worker loop runs until the context is cancelled (SIGTERM).
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		runWorker(ctx, log, os.Getenv("AMQP_URL"))
	}()

	select {
	case err := <-srvErr:
		log.Error("health server failed", "err", err)
		stop()
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown failed", "err", err)
	}
	<-workerDone
	log.Info("shutdown complete")
}

// runWorker consumes the queue, or idles if no broker is configured. It always
// returns when ctx is cancelled (no goroutine leak).
func runWorker(ctx context.Context, log *slog.Logger, amqpURL string) {
	if amqpURL == "" {
		log.Info("AMQP_URL unset; worker idling (heartbeat every 30s)")
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				log.Info("payments-worker idle heartbeat (no queue configured)")
			}
		}
	}

	// Reconnect loop: on any connection error, back off and retry until ctx done.
	for {
		if err := consume(ctx, log, amqpURL); err != nil && ctx.Err() == nil {
			log.Warn("consume loop error; retrying in 5s", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
			continue
		}
		return
	}
}

func consume(ctx context.Context, log *slog.Logger, amqpURL string) error {
	conn, err := amqp.Dial(amqpURL)
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
	if err := ch.Qos(8, 0, false); err != nil {
		return err
	}
	deliveries, err := ch.Consume(queueName, "payments-worker", false, false, false, false, nil)
	if err != nil {
		return err
	}
	log.Info("consuming queue", "queue", queueName)

	for {
		select {
		case <-ctx.Done():
			return nil
		case d, ok := <-deliveries:
			if !ok {
				return errors.New("delivery channel closed")
			}
			var evt struct {
				OrderID int64 `json:"order_id"`
			}
			_ = json.Unmarshal(d.Body, &evt)
			// "Process" the payment. Real logic would call a PSP here.
			log.Info("processed payment for order", "order_id", evt.OrderID)
			paymentsProcessed.Inc()
			if err := d.Ack(false); err != nil {
				log.Warn("ack failed", "err", err)
			}
		}
	}
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
