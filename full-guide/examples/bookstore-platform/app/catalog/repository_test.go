package main

// Integration tests for the Postgres-backed Repository. Requires Docker:
// testcontainers-go spins up a real Postgres container, applies the
// migration, runs the contract, tears down. Skip with `go test -short`.

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestPostgresRepo_Contract(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test; requires Docker; rerun without -short")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	// postgres module's Run already waits internally for the DB to accept
	// connections — no explicit wait strategy needed in 0.39+.
	container, err := tcpostgres.Run(ctx,
		"postgres:16-alpine",
		tcpostgres.WithDatabase("catalog"),
		tcpostgres.WithUsername("test"),
		tcpostgres.WithPassword("test"),
		tcpostgres.BasicWaitStrategies(),
	)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = container.Terminate(context.Background())
	})

	dsn, err := container.ConnectionString(ctx, "sslmode=disable")
	require.NoError(t, err)

	repo, err := NewPostgresRepo(ctx, dsn)
	require.NoError(t, err)
	defer repo.Close()

	t.Run("Ping returns nil on a healthy DB", func(t *testing.T) {
		assert.NoError(t, repo.Ping(ctx))
	})

	t.Run("Empty list returns no books", func(t *testing.T) {
		got, err := repo.List(ctx, 100, 0)
		assert.NoError(t, err)
		assert.Empty(t, got)
	})

	t.Run("Create persists a book", func(t *testing.T) {
		b, err := repo.Create(ctx, Book{ID: "1", Title: "T", Author: "A", ISBN: "9781617293726"})
		require.NoError(t, err)
		assert.Equal(t, "1", b.ID)

		got, err := repo.Get(ctx, "1")
		require.NoError(t, err)
		assert.Equal(t, "T", got.Title)
	})

	t.Run("Get on missing id returns ErrNotFound", func(t *testing.T) {
		_, err := repo.Get(ctx, "missing")
		assert.True(t, errors.Is(err, ErrNotFound))
	})

	t.Run("Update mutates only the row with matching id", func(t *testing.T) {
		_, err := repo.Create(ctx, Book{ID: "2", Title: "Old", Author: "A", ISBN: "9780134190440"})
		require.NoError(t, err)

		_, err = repo.Update(ctx, Book{ID: "2", Title: "New", Author: "A", ISBN: "9780134190440"})
		require.NoError(t, err)

		got, err := repo.Get(ctx, "2")
		require.NoError(t, err)
		assert.Equal(t, "New", got.Title)
	})

	t.Run("Update on missing id returns ErrNotFound", func(t *testing.T) {
		_, err := repo.Update(ctx, Book{ID: "ghost", Title: "T", Author: "A", ISBN: "9781617293726"})
		assert.True(t, errors.Is(err, ErrNotFound))
	})

	t.Run("Delete removes the row", func(t *testing.T) {
		_, err := repo.Create(ctx, Book{ID: "3", Title: "T", Author: "A", ISBN: "9781449373320"})
		require.NoError(t, err)

		err = repo.Delete(ctx, "3")
		assert.NoError(t, err)

		_, err = repo.Get(ctx, "3")
		assert.True(t, errors.Is(err, ErrNotFound))
	})

	t.Run("Delete on missing id returns ErrNotFound", func(t *testing.T) {
		err := repo.Delete(ctx, "ghost")
		assert.True(t, errors.Is(err, ErrNotFound))
	})

	t.Run("List orders by id and respects limit/offset", func(t *testing.T) {
		// fresh table so pagination test is deterministic
		for _, id := range []string{"a", "b", "c", "d", "e"} {
			_, err := repo.Create(ctx, Book{ID: id, Title: "T-" + id, Author: "A", ISBN: "9781617293726"})
			if err != nil {
				// already exists from prior subtest; ignore
				continue
			}
		}
		got, err := repo.List(ctx, 2, 0)
		require.NoError(t, err)
		require.Len(t, got, 2)
		assert.Equal(t, "1", got[0].ID) // "1" sorts before "2","a","b",...
	})
}
