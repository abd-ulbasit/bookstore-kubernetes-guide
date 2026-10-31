package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// kafkaTLSFromEnv returns the client TLS config named by KAFKA_TLS_DIR, or nil
// (plaintext) when the variable is unset.
func kafkaTLSFromEnv() (*tls.Config, error) {
	dir := os.Getenv("KAFKA_TLS_DIR")
	if dir == "" {
		return nil, nil
	}
	return kafkaTLS(dir)
}

// kafkaTLS reads a KafkaUser secret mounted at dir. ca.crt, the cluster CA,
// verifies the broker. user.crt and user.key identify this client to the TLS
// listener, which refuses a client certificate it did not sign.
func kafkaTLS(dir string) (*tls.Config, error) {
	ca, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return nil, fmt.Errorf("read cluster CA: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, errors.New("cluster CA holds no PEM certificate")
	}
	cert, err := tls.LoadX509KeyPair(filepath.Join(dir, "user.crt"), filepath.Join(dir, "user.key"))
	if err != nil {
		return nil, fmt.Errorf("load client certificate: %w", err)
	}
	return &tls.Config{RootCAs: pool, Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, nil
}
