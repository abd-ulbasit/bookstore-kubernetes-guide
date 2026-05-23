package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Repository is the persistence interface for Book. Defined as an interface
// so handlers can be unit-tested with an in-memory fake, and integration
// tests can swap to the real Postgres-backed implementation behind the
// same contract.
type Repository interface {
	List(ctx context.Context, limit, offset int) ([]Book, error)
	Get(ctx context.Context, id string) (Book, error)
	Create(ctx context.Context, b Book) (Book, error)
	Update(ctx context.Context, b Book) (Book, error)
	Delete(ctx context.Context, id string) error
	Ping(ctx context.Context) error
}

// PostgresRepo is the pgx-backed Repository. Pool is goroutine-safe;
// callers share one instance for the lifetime of the process.
type PostgresRepo struct {
	pool *pgxpool.Pool
}

// NewPostgresRepo connects with the given DSN, applies a small idempotent
// schema migration so a fresh database is immediately usable, and returns
// a ready Repository. Cancel ctx to abort connection attempts during boot.
func NewPostgresRepo(ctx context.Context, dsn string) (*PostgresRepo, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	// Conservative pool defaults — the bookstore Postgres in the Helm chart
	// is sized for development. Production overrides via env: see
	// PGX_MAX_CONNS in deployment.yaml.
	cfg.MaxConns = 8
	cfg.MinConns = 1

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	r := &PostgresRepo{pool: pool}
	if err := r.migrate(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return r, nil
}

// Close releases the underlying connection pool.
func (r *PostgresRepo) Close() { r.pool.Close() }

func (r *PostgresRepo) Ping(ctx context.Context) error { return r.pool.Ping(ctx) }

// migrate creates the books table if it doesn't exist. Idempotent. In
// production this would live behind a proper migration tool (golang-migrate)
// run as a Kubernetes Job before the Deployment starts — the chapter that
// teaches this also references migrations/001_books.sql which is the
// authoritative source.
func (r *PostgresRepo) migrate(ctx context.Context) error {
	const ddl = `
CREATE TABLE IF NOT EXISTS books (
	id     TEXT PRIMARY KEY,
	title  TEXT NOT NULL,
	author TEXT NOT NULL,
	isbn   TEXT NOT NULL UNIQUE
);`
	_, err := r.pool.Exec(ctx, ddl)
	return err
}

// List returns up to limit books, skipping offset, sorted by id for
// stable pagination. limit ≤ 0 → 50, capped at 200.
func (r *PostgresRepo) List(ctx context.Context, limit, offset int) ([]Book, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	if offset < 0 {
		offset = 0
	}
	rows, err := r.pool.Query(ctx,
		`SELECT id, title, author, isbn FROM books ORDER BY id LIMIT $1 OFFSET $2`,
		limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Book, 0, limit)
	for rows.Next() {
		var b Book
		if err := rows.Scan(&b.ID, &b.Title, &b.Author, &b.ISBN); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (r *PostgresRepo) Get(ctx context.Context, id string) (Book, error) {
	var b Book
	err := r.pool.QueryRow(ctx,
		`SELECT id, title, author, isbn FROM books WHERE id = $1`, id).
		Scan(&b.ID, &b.Title, &b.Author, &b.ISBN)
	if errors.Is(err, pgx.ErrNoRows) {
		return Book{}, ErrNotFound
	}
	return b, err
}

func (r *PostgresRepo) Create(ctx context.Context, b Book) (Book, error) {
	if err := b.Validate(); err != nil {
		return Book{}, err
	}
	_, err := r.pool.Exec(ctx,
		`INSERT INTO books (id, title, author, isbn) VALUES ($1, $2, $3, $4)`,
		b.ID, b.Title, b.Author, b.ISBN)
	if err != nil {
		return Book{}, err
	}
	return b, nil
}

func (r *PostgresRepo) Update(ctx context.Context, b Book) (Book, error) {
	if err := b.Validate(); err != nil {
		return Book{}, err
	}
	tag, err := r.pool.Exec(ctx,
		`UPDATE books SET title=$2, author=$3, isbn=$4 WHERE id=$1`,
		b.ID, b.Title, b.Author, b.ISBN)
	if err != nil {
		return Book{}, err
	}
	if tag.RowsAffected() == 0 {
		return Book{}, ErrNotFound
	}
	return b, nil
}

func (r *PostgresRepo) Delete(ctx context.Context, id string) error {
	tag, err := r.pool.Exec(ctx, `DELETE FROM books WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// MemRepo is an in-memory Repository used by handler unit tests. Not safe
// for concurrent use; tests serialise their own access.
type MemRepo struct {
	Books map[string]Book
}

func NewMemRepo() *MemRepo { return &MemRepo{Books: map[string]Book{}} }

func (m *MemRepo) Ping(context.Context) error { return nil }

func (m *MemRepo) List(_ context.Context, limit, offset int) ([]Book, error) {
	if limit <= 0 {
		limit = 50
	}
	out := make([]Book, 0, len(m.Books))
	for _, b := range m.Books {
		out = append(out, b)
	}
	// Sort by ID so order is deterministic in tests.
	// Inline insertion sort keeps the file dep-free.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j-1].ID > out[j].ID; j-- {
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	if offset >= len(out) {
		return []Book{}, nil
	}
	end := offset + limit
	if end > len(out) {
		end = len(out)
	}
	return out[offset:end], nil
}

func (m *MemRepo) Get(_ context.Context, id string) (Book, error) {
	b, ok := m.Books[id]
	if !ok {
		return Book{}, ErrNotFound
	}
	return b, nil
}

func (m *MemRepo) Create(_ context.Context, b Book) (Book, error) {
	if err := b.Validate(); err != nil {
		return Book{}, err
	}
	if _, exists := m.Books[b.ID]; exists {
		return Book{}, fmt.Errorf("id %q exists", b.ID)
	}
	m.Books[b.ID] = b
	return b, nil
}

func (m *MemRepo) Update(_ context.Context, b Book) (Book, error) {
	if err := b.Validate(); err != nil {
		return Book{}, err
	}
	if _, exists := m.Books[b.ID]; !exists {
		return Book{}, ErrNotFound
	}
	m.Books[b.ID] = b
	return b, nil
}

func (m *MemRepo) Delete(_ context.Context, id string) error {
	if _, exists := m.Books[id]; !exists {
		return ErrNotFound
	}
	delete(m.Books, id)
	return nil
}
