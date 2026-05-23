package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// newTestServer assembles a Server wired to a fresh in-memory repo and a
// fresh Prometheus registry so tests don't share state.
func newTestServer(t *testing.T, seed ...Book) (*Server, *MemRepo) {
	t.Helper()
	repo := NewMemRepo()
	for _, b := range seed {
		_, err := repo.Create(context.Background(), b)
		require.NoError(t, err, "seed book")
	}
	return &Server{
		Repo:    repo,
		Log:     slog.New(slog.NewJSONHandler(io_Discard{}, nil)),
		Metrics: NewMetrics(prometheus.NewRegistry()),
	}, repo
}

// io_Discard is a local io.Discard avoiding an import.
type io_Discard struct{}

func (io_Discard) Write(p []byte) (int, error) { return len(p), nil }

func sampleBook(id string) Book {
	return Book{ID: id, Title: "Title " + id, Author: "Author " + id, ISBN: "9781617293726"}
}

func TestHealthz_AlwaysOK(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.JSONEq(t, `{"status":"ok"}`, w.Body.String())
}

func TestReadyz_OK(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code)
}

func TestListBooks_TableDriven(t *testing.T) {
	tests := []struct {
		name       string
		seed       []Book
		query      string
		wantStatus int
		wantCount  int
	}{
		{"empty", nil, "", http.StatusOK, 0},
		{"three books", []Book{sampleBook("1"), sampleBook("2"), sampleBook("3")}, "", http.StatusOK, 3},
		{"limit clamps to count", []Book{sampleBook("1"), sampleBook("2")}, "?limit=10", http.StatusOK, 2},
		{"offset past end", []Book{sampleBook("1")}, "?offset=10", http.StatusOK, 0},
		{"limit=1 returns one", []Book{sampleBook("1"), sampleBook("2"), sampleBook("3")}, "?limit=1", http.StatusOK, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newTestServer(t, tc.seed...)
			req := httptest.NewRequest(http.MethodGet, "/books"+tc.query, nil)
			w := httptest.NewRecorder()
			srv.Routes().ServeHTTP(w, req)
			assert.Equal(t, tc.wantStatus, w.Code)

			var out struct {
				Books []Book `json:"books"`
			}
			require.NoError(t, json.NewDecoder(w.Body).Decode(&out))
			assert.Len(t, out.Books, tc.wantCount)
		})
	}
}

func TestGetBook(t *testing.T) {
	srv, _ := newTestServer(t, sampleBook("42"))
	t.Run("found", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/books/42", nil)
		w := httptest.NewRecorder()
		srv.Routes().ServeHTTP(w, req)
		assert.Equal(t, http.StatusOK, w.Code)
		var got Book
		require.NoError(t, json.NewDecoder(w.Body).Decode(&got))
		assert.Equal(t, "42", got.ID)
	})
	t.Run("not found", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/books/does-not-exist", nil)
		w := httptest.NewRecorder()
		srv.Routes().ServeHTTP(w, req)
		assert.Equal(t, http.StatusNotFound, w.Code)
	})
}

func TestCreateBook(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{
			"happy path",
			`{"id":"a","title":"T","author":"A","isbn":"9781617293726"}`,
			http.StatusCreated,
		},
		{
			"missing title",
			`{"id":"a","title":"","author":"A","isbn":"9781617293726"}`,
			http.StatusBadRequest,
		},
		{
			"bad ISBN",
			`{"id":"a","title":"T","author":"A","isbn":"not-an-isbn"}`,
			http.StatusBadRequest,
		},
		{
			"malformed json",
			`not json at all`,
			http.StatusBadRequest,
		},
		{
			"isbn-10 with X check digit normalised",
			`{"id":"b","title":"T","author":"A","isbn":"0-306-40615-X"}`,
			http.StatusCreated,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newTestServer(t)
			req := httptest.NewRequest(http.MethodPost, "/books", strings.NewReader(tc.body))
			w := httptest.NewRecorder()
			srv.Routes().ServeHTTP(w, req)
			assert.Equal(t, tc.wantStatus, w.Code, "body: %s", w.Body.String())
		})
	}
}

func TestUpdateBook(t *testing.T) {
	srv, repo := newTestServer(t, sampleBook("1"))

	body := `{"title":"new title","author":"new author","isbn":"9781617293726"}`
	req := httptest.NewRequest(http.MethodPut, "/books/1", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.Equal(t, "new title", repo.Books["1"].Title)
	assert.Equal(t, "new author", repo.Books["1"].Author)

	// id from path wins over body
	req2 := httptest.NewRequest(http.MethodPut, "/books/missing",
		bytes.NewBufferString(`{"id":"1","title":"x","author":"y","isbn":"9781617293726"}`))
	w2 := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w2, req2)
	assert.Equal(t, http.StatusNotFound, w2.Code)
}

func TestDeleteBook(t *testing.T) {
	srv, repo := newTestServer(t, sampleBook("1"))

	req := httptest.NewRequest(http.MethodDelete, "/books/1", nil)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	assert.Equal(t, http.StatusNoContent, w.Code)
	_, exists := repo.Books["1"]
	assert.False(t, exists)

	// idempotency: second delete returns 404
	req2 := httptest.NewRequest(http.MethodDelete, "/books/1", nil)
	w2 := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w2, req2)
	assert.Equal(t, http.StatusNotFound, w2.Code)
}

func TestMetricsEndpoint_Exposes_Expected_Series(t *testing.T) {
	srv, _ := newTestServer(t, sampleBook("1"))
	// generate some traffic
	for range 5 {
		srv.Routes().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/books", nil))
	}
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code)
	body := w.Body.String()
	assert.Contains(t, body, `catalog_http_requests_total`)
	assert.Contains(t, body, `catalog_http_request_duration_seconds`)
}

func TestNormalisePath(t *testing.T) {
	tests := map[string]string{
		"/healthz":   "/healthz",
		"/readyz":    "/readyz",
		"/metrics":   "/metrics",
		"/books":     "/books",
		"/books/42":  "/books/{id}",
		"/books/abc": "/books/{id}",
		"/unknown":   "/unknown",
	}
	for in, want := range tests {
		assert.Equal(t, want, normalisePath(in), "input=%q", in)
	}
}

func TestStatusClass(t *testing.T) {
	for code, want := range map[int]string{
		100: "1xx", 200: "2xx", 201: "2xx", 301: "3xx",
		400: "4xx", 404: "4xx", 500: "5xx", 503: "5xx",
	} {
		assert.Equal(t, want, statusClass(code))
	}
}
