// Command payments-gateway is the Bookstore Platform v2 service that
// talks to Stripe. Two modes selected by PAYMENTS_MODE: "gateway"
// (POST /charge -> Stripe PaymentIntents with event_id as
// IdempotencyKey) and "webhook-receiver" (POST /stripe/webhook ->
// verify Stripe-Signature -> publish payment_intent.succeeded to
// `payments.completed` or payment_intent.payment_failed to
// `payments.failed`). Intentionally small (<=200 lines).
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
	"strings"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
	"github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/paymentintent"
	"github.com/stripe/stripe-go/v76/webhook"
)

type config struct {
	mode, port, stripeKey, stripeAPIBase, webhookSecret string
	kafkaBrokers                                        []string
	topicCompleted, topicFailed                         string
}

// webhookPublisher bundles the Kafka writers used by the webhook handler.
// One writer per topic; both use at-least-once delivery (acks=all).
// Consumers dedupe on event_id.
type webhookPublisher struct {
	completed, failed *kafka.Writer
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := config{
		mode:           envOr("PAYMENTS_MODE", "gateway"),
		port:           envOr("PORT", "8080"),
		stripeKey:      os.Getenv("STRIPE_KEY"),
		stripeAPIBase:  os.Getenv("STRIPE_API_BASE"),
		webhookSecret:  os.Getenv("STRIPE_WEBHOOK_SECRET"),
		kafkaBrokers:   strings.Split(envOr("KAFKA_BROKERS", "bookstore-platform-kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9092"), ","),
		topicCompleted: envOr("KAFKA_TOPIC_PAYMENTS_COMPLETED", "payments.completed"),
		topicFailed:    envOr("KAFKA_TOPIC_PAYMENTS_FAILED", "payments.failed"),
	}

	// Stripe SDK init. STRIPE_API_BASE points at stripe-mock for kind tests.
	if cfg.stripeKey != "" {
		stripe.Key = cfg.stripeKey
	}
	if cfg.stripeAPIBase != "" {
		stripe.SetBackend(stripe.APIBackend, stripe.GetBackendWithConfig(stripe.APIBackend, &stripe.BackendConfig{URL: stripe.String(cfg.stripeAPIBase)}))
	}

	// Webhook mode initializes Kafka writers; gateway mode does not.
	var pub *webhookPublisher
	if cfg.mode == "webhook-receiver" {
		pub = &webhookPublisher{
			completed: &kafka.Writer{Addr: kafka.TCP(cfg.kafkaBrokers...), Topic: cfg.topicCompleted, Balancer: &kafka.Hash{}, RequiredAcks: kafka.RequireAll},
			failed:    &kafka.Writer{Addr: kafka.TCP(cfg.kafkaBrokers...), Topic: cfg.topicFailed, Balancer: &kafka.Hash{}, RequiredAcks: kafka.RequireAll},
		}
		defer pub.completed.Close()
		defer pub.failed.Close()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ok"}`)) })
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"status":"ready"}`)) })
	mux.HandleFunc("POST /charge", handleCharge(log))
	mux.HandleFunc("POST /stripe/webhook", handleWebhook(cfg, pub, log))

	srv := &http.Server{Addr: ":" + cfg.port, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		log.Info("payments-gateway listening", "addr", srv.Addr, "mode", cfg.mode)
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
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

// handleCharge invokes Stripe PaymentIntents for an order. event_id from
// Kafka becomes Stripe's IdempotencyKey — the same Kafka message arriving
// twice produces the same Stripe charge at most once.
func handleCharge(log *slog.Logger) http.HandlerFunc {
	type req struct {
		EventID, OrderID, Currency, Customer string
		Amount                               int64 `json:"amount_cents"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		var p req
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&p); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid body")
			return
		}
		if p.EventID == "" || p.Amount <= 0 {
			writeErr(w, http.StatusBadRequest, "missing event_id or amount")
			return
		}
		params := &stripe.PaymentIntentParams{
			Amount: stripe.Int64(p.Amount), Currency: stripe.String(strings.ToLower(p.Currency)),
			Customer: stripe.String(p.Customer), Confirm: stripe.Bool(true),
			PaymentMethod: stripe.String("pm_card_visa"),
		}
		params.IdempotencyKey = stripe.String(p.EventID) // THE idempotency contract
		params.AddMetadata("order_id", p.OrderID)
		pi, err := paymentintent.New(params)
		if err != nil {
			log.Error("stripe call failed", "err", err, "event_id", p.EventID)
			writeErr(w, http.StatusBadGateway, "stripe call failed")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"payment_intent_id": pi.ID, "status": string(pi.Status)})
	}
}

// handleWebhook verifies Stripe-Signature BEFORE doing anything else.
// On a verified event it publishes to Kafka — payments.completed on
// success, payments.failed on failure — then 200s Stripe. Other event
// types are logged and acked without publishing. A Kafka write failure
// returns 500 so Stripe retries.
func handleWebhook(cfg config, pub *webhookPublisher, log *slog.Logger) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "read body failed")
			return
		}
		sig := r.Header.Get("Stripe-Signature")
		if sig == "" {
			writeErr(w, http.StatusBadRequest, "missing stripe-signature header")
			return
		}
		evt, err := webhook.ConstructEvent(body, sig, cfg.webhookSecret)
		if err != nil {
			log.Warn("webhook signature verification failed", "err", err)
			writeErr(w, http.StatusUnauthorized, "invalid signature")
			return
		}
		// Decode the payment_intent object to carry order_id + payment_intent_id forward.
		var pi struct {
			ID       string            `json:"id"`
			Metadata map[string]string `json:"metadata"`
		}
		_ = json.Unmarshal(evt.Data.Raw, &pi)
		out, _ := json.Marshal(map[string]string{
			"event_id": evt.ID, "type": string(evt.Type),
			"payment_intent_id": pi.ID, "order_id": pi.Metadata["order_id"],
		})
		var writer *kafka.Writer
		switch evt.Type {
		case "payment_intent.succeeded":
			writer = pub.completed
		case "payment_intent.payment_failed":
			writer = pub.failed
		default:
			log.Info("webhook event ignored", "type", evt.Type, "id", evt.ID)
			respondAck(w, evt.ID)
			return
		}
		if pub == nil || writer == nil {
			writeErr(w, http.StatusInternalServerError, "publisher not initialised")
			return
		}
		if err := writer.WriteMessages(r.Context(), kafka.Message{Key: []byte(evt.ID), Value: out}); err != nil {
			log.Error("kafka publish failed", "err", err, "event_id", evt.ID, "type", evt.Type)
			writeErr(w, http.StatusInternalServerError, "kafka publish failed")
			return
		}
		log.Info("webhook event handled", "type", evt.Type, "id", evt.ID)
		respondAck(w, evt.ID)
	}
}

func respondAck(w http.ResponseWriter, id string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"received": id})
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
