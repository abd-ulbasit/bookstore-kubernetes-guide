package main

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

func Test_errClass(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want string
	}{
		{"deadline", context.DeadlineExceeded, "timeout"},
		{"network", &net.OpError{Op: "dial", Err: errors.New("refused")}, "network"},
		{"other", errors.New("boom"), "other"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := errClass(tc.err); got != tc.want {
				t.Fatalf("errClass() = %q, want %q", got, tc.want)
			}
		})
	}
}

// Test_errClass_dsnParse gives the driver a DSN it cannot parse. It checks the
// class and that no DSN text reaches the log line built from it.
func Test_errClass_dsnParse(t *testing.T) {
	const secret = "FAKE-PLANTED-PASSWORD"
	_, err := pgxpool.New(context.Background(), "postgres://app:"+secret+"%zz@localhost:5432/books")
	if err == nil {
		t.Fatal("expected a parse error")
	}
	if got := errClass(err); got != "dsn_parse" {
		t.Fatalf("errClass() = %q, want dsn_parse", got)
	}
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	log.Error("connect postgres", "error_class", errClass(err))
	if strings.Contains(buf.String(), secret) || strings.Contains(buf.String(), "localhost") {
		t.Fatalf("log line carries DSN text: %s", buf.String())
	}
}
