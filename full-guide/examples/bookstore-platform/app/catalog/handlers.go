package main

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

// Server bundles the HTTP handler dependencies. Repository is the
// persistence layer; Metrics is the observability surface.
type Server struct {
	Repo    Repository
	Log     *slog.Logger
	Metrics *Metrics
}

// Routes returns a configured http.Handler with metrics + logging middleware
// already wrapped around the application handlers.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.Handle("GET /metrics", s.Metrics.Handler())

	mux.HandleFunc("GET /books", s.listBooks)
	mux.HandleFunc("GET /books/{id}", s.getBook)
	mux.HandleFunc("POST /books", s.createBook)
	mux.HandleFunc("PUT /books/{id}", s.updateBook)
	mux.HandleFunc("DELETE /books/{id}", s.deleteBook)

	return s.withInstrumentation(mux)
}

// withInstrumentation wraps every request with timing + status capture so
// Prometheus + structured logs see consistent data.
func (s *Server) withInstrumentation(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		dur := time.Since(start)
		s.Metrics.Observe(r.Method, normalisePath(r.URL.Path), rec.status, dur)
		s.Log.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", dur.Milliseconds(),
		)
	})
}

// healthz answers liveness: are we still here? Always 200.
func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// readyz answers readiness: can we serve traffic? Checks the database round-trip.
func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := contextWithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.Repo.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db unavailable", "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) listBooks(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	books, err := s.Repo.List(r.Context(), limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"books": books, "limit": limit, "offset": offset})
}

func (s *Server) getBook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	b, err := s.Repo.Get(r.Context(), id)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err)
	case err != nil:
		writeError(w, http.StatusInternalServerError, err)
	default:
		writeJSON(w, http.StatusOK, b)
	}
}

func (s *Server) createBook(w http.ResponseWriter, r *http.Request) {
	var b Book
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	out, err := s.Repo.Create(r.Context(), b)
	switch {
	case errors.Is(err, ErrInvalid):
		writeError(w, http.StatusBadRequest, err)
	case err != nil:
		writeError(w, http.StatusInternalServerError, err)
	default:
		writeJSON(w, http.StatusCreated, out)
	}
}

func (s *Server) updateBook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var b Book
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	b.ID = id // path id wins
	out, err := s.Repo.Update(r.Context(), b)
	switch {
	case errors.Is(err, ErrInvalid):
		writeError(w, http.StatusBadRequest, err)
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err)
	case err != nil:
		writeError(w, http.StatusInternalServerError, err)
	default:
		writeJSON(w, http.StatusOK, out)
	}
}

func (s *Server) deleteBook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	err := s.Repo.Delete(r.Context(), id)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, err)
	case err != nil:
		writeError(w, http.StatusInternalServerError, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// --- helpers ---

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"error": err.Error()})
}

// normalisePath maps `/books/123` → `/books/{id}` so the per-path metric
// cardinality stays bounded. Anything starting with /books/ is collapsed.
func normalisePath(p string) string {
	switch {
	case p == "/books":
		return "/books"
	case len(p) > len("/books/") && p[:len("/books/")] == "/books/":
		return "/books/{id}"
	default:
		return p
	}
}

// contextWithTimeout is a tiny indirection so callers don't have to import
// context everywhere when they really just want a deadline-bounded child.
func contextWithTimeout(parent contextLike, d time.Duration) (contextLike, func()) {
	// Re-export of context.WithTimeout with a lightweight interface; keeps
	// the test-side fakes from having to import context just to satisfy the
	// signature.
	return contextWithTimeoutImpl(parent, d)
}
