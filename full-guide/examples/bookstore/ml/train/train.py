"""
Bookstore recommendations — CPU-only training (Part 12 ch.04, X3b).

Trains the item-kNN / co-occurrence recommendations model from the Bookstore's
own schema (`books` + `orders`, the schema created by
`examples/bookstore/raw-manifests/21-db-migrate-job.yaml`). Deliberately tiny so
the entire train -> serve loop runs CPU-only on kind, no GPU.

What it does
------------
1. Generate a synthetic, *seeded*, reproducible dataset whose shape matches the
   real `books` and `orders` tables (this matches `dataset/README.md`). Real
   columns: books(id, title, author, price); orders(id, book_id, qty,
   created_at). No real DB connection is required (and there isn't one on kind
   here) — the seed makes the model reproducible.
2. Group `orders` into pseudo-baskets via the documented `basket proxy` (a
   synthetic `customer_id` assigned by the generator).
3. Build a sparse customer x book interaction matrix and compute item-item
   cosine similarity (the book x book matrix); keep the top-K neighbours per
   book — the recommendations model.
4. Persist as `model.joblib` under MODEL_DIR (default `/workspace/model`) so
   the serving predictor (`../serve/predictor.py`) can load it.

Honest scope
------------
This is a textbook item-kNN/co-occurrence recommender — no deep learning, no
GPU. It is real ML, but the workload is CPU-trivial; the value is that the
train -> joblib artifact -> serve loop is genuinely end-to-end runnable on a
laptop kind cluster. The GPU "scale up" path is Part 12 ch.02
(`../gpu/recommender-train-gpu.yaml`); the gang/Kueue/JobSet path is ch.03
(`../batch/`); this file is the CPU artifact ch.04 uses.

Determinism
-----------
Fully deterministic for a given `SEED` (default 42). Re-running produces the
same model artifact and the same recommendations.

Env vars
--------
MODEL_DIR    output dir for model.joblib (default: /workspace/model)
SEED         RNG seed (default: 42)
N_BOOKS      synthetic books to generate (default: 200)
N_CUSTOMERS  synthetic customers/baskets (default: 800)
N_ORDERS     synthetic order rows (default: 5000)
TOP_K        neighbours per book to keep in the model (default: 10)
"""
from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import dataclass

import joblib
import numpy as np
from scipy.sparse import csr_matrix
from sklearn.metrics.pairwise import cosine_similarity


# ----- Configuration -------------------------------------------------------

@dataclass(frozen=True)
class Config:
    model_dir: str
    seed: int
    n_books: int
    n_customers: int
    n_orders: int
    top_k: int

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            model_dir=os.environ.get("MODEL_DIR", "/workspace/model"),
            seed=int(os.environ.get("SEED", "42")),
            n_books=int(os.environ.get("N_BOOKS", "200")),
            n_customers=int(os.environ.get("N_CUSTOMERS", "800")),
            n_orders=int(os.environ.get("N_ORDERS", "5000")),
            top_k=int(os.environ.get("TOP_K", "10")),
        )


# ----- Synthetic dataset (Bookstore-schema shaped) -------------------------

def generate_books(rng: np.random.Generator, n: int) -> list[dict]:
    """books(id SERIAL, title TEXT, author TEXT, price NUMERIC)."""
    authors = [f"Author {i:03d}" for i in range(1, max(2, n // 5) + 1)]
    rows: list[dict] = []
    for i in range(1, n + 1):
        rows.append({
            "id": i,
            "title": f"Book {i:04d}",
            "author": str(rng.choice(authors)),
            # `NUMERIC` -> float; the migration uses NUMERIC, not cents.
            "price": round(float(rng.uniform(5.0, 60.0)), 2),
        })
    return rows


def generate_orders(
    rng: np.random.Generator,
    n_books: int,
    n_customers: int,
    n_orders: int,
) -> list[dict]:
    """orders(id SERIAL, book_id INT, qty INT, created_at TIMESTAMPTZ).

    Uses the documented `basket proxy`: each order is assigned a synthetic
    customer_id (NOT a real column in the schema) so we can compute item
    co-occurrence. Plants mild popularity skew + a few "bought together"
    affinities so the learned neighbours are non-trivial.
    """
    # Popularity: Zipf-ish skew so a long tail and a head of popular books.
    pop_weights = 1.0 / np.arange(1, n_books + 1)
    pop_weights = pop_weights / pop_weights.sum()

    # Plant a handful of affinity pairs (book A often bought with book B).
    n_affinity_pairs = max(5, n_books // 25)
    affinity_pairs: list[tuple[int, int]] = []
    for _ in range(n_affinity_pairs):
        a, b = rng.choice(n_books, size=2, replace=False)
        # Convert to 1-based ids (matches SERIAL).
        affinity_pairs.append((int(a) + 1, int(b) + 1))

    rows: list[dict] = []
    order_id = 0
    # Pre-assign each order to a customer; later we may pair-plant.
    customer_ids = rng.integers(low=1, high=n_customers + 1, size=n_orders)
    base_ts = int(time.time()) - 60 * 60 * 24 * 30  # 30 days ago
    for i in range(n_orders):
        book_id = int(rng.choice(n_books, p=pop_weights) + 1)
        order_id += 1
        rows.append({
            "id": order_id,
            "book_id": book_id,
            "qty": int(rng.integers(1, 4)),
            "created_at": base_ts + i,  # monotonically increasing
            "_customer_id": int(customer_ids[i]),   # basket proxy (synthetic)
        })

    # Plant affinity co-purchases: for ~10% of orders involving a book in an
    # affinity pair, add a paired order under the same customer.
    extra: list[dict] = []
    for r in rows:
        for a, b in affinity_pairs:
            if r["book_id"] == a and rng.random() < 0.30:
                order_id += 1
                extra.append({
                    "id": order_id,
                    "book_id": b,
                    "qty": 1,
                    "created_at": r["created_at"] + 1,
                    "_customer_id": r["_customer_id"],
                })
    rows.extend(extra)
    return rows


# ----- Item-kNN / co-occurrence model --------------------------------------

def build_interaction_matrix(
    orders: list[dict], n_books: int, n_customers: int,
) -> csr_matrix:
    """Sparse customer x book interaction matrix (binary: bought-or-not)."""
    row_idx = np.array([o["_customer_id"] - 1 for o in orders], dtype=np.int64)
    col_idx = np.array([o["book_id"] - 1 for o in orders], dtype=np.int64)
    data = np.ones(len(orders), dtype=np.float32)
    m = csr_matrix(
        (data, (row_idx, col_idx)),
        shape=(n_customers, n_books),
        dtype=np.float32,
    )
    # Collapse duplicate (customer, book) interactions to a single 1.
    m.data[:] = 1.0
    m.sum_duplicates()
    m.data[:] = 1.0
    return m


def topk_neighbours(
    interactions: csr_matrix, top_k: int,
) -> dict[int, list[tuple[int, float]]]:
    """Return {book_id (1-based): [(neighbour_book_id, score), ...]}."""
    # book x book cosine similarity via the customer x book matrix.
    item_user = interactions.T.tocsr()  # book x customer
    # cosine_similarity on a sparse matrix returns a dense N x N — fine for
    # the tiny N here (e.g. 200). For larger N use sklearn NearestNeighbors.
    sim = cosine_similarity(item_user, dense_output=True)
    np.fill_diagonal(sim, 0.0)  # a book is never its own neighbour
    model: dict[int, list[tuple[int, float]]] = {}
    n_books = sim.shape[0]
    k = min(top_k, n_books - 1)
    for i in range(n_books):
        # argpartition for top-k indices, then sort that small slice.
        idx = np.argpartition(-sim[i], kth=k)[:k]
        idx = idx[np.argsort(-sim[i, idx])]
        model[i + 1] = [(int(j + 1), float(sim[i, j])) for j in idx]
    return model


# ----- Driver --------------------------------------------------------------

def main() -> int:
    cfg = Config.from_env()
    print(f"[train] config={cfg}", flush=True)
    rng = np.random.default_rng(cfg.seed)

    print(f"[train] generating {cfg.n_books} books / {cfg.n_orders} orders "
          f"across {cfg.n_customers} synthetic customers (basket proxy)",
          flush=True)
    books = generate_books(rng, cfg.n_books)
    orders = generate_orders(rng, cfg.n_books, cfg.n_customers, cfg.n_orders)
    print(f"[train] dataset: books={len(books)} orders={len(orders)}",
          flush=True)

    print("[train] building customer x book interaction matrix", flush=True)
    inter = build_interaction_matrix(orders, cfg.n_books, cfg.n_customers)
    print(f"[train] interactions: shape={inter.shape} nnz={inter.nnz}",
          flush=True)

    print(f"[train] computing item-item cosine similarity, top_k={cfg.top_k}",
          flush=True)
    neighbours = topk_neighbours(inter, cfg.top_k)

    # Persist the model: the top-K neighbour map + a tiny books index for
    # nicer responses from the predictor (title/author lookup).
    books_index = {b["id"]: {"title": b["title"], "author": b["author"]}
                   for b in books}
    artifact = {
        "version": 1,
        "kind": "item-knn-cooccurrence",
        "seed": cfg.seed,
        "n_books": cfg.n_books,
        "n_customers": cfg.n_customers,
        "n_orders": len(orders),
        "top_k": cfg.top_k,
        "neighbours": neighbours,
        "books_index": books_index,
    }
    os.makedirs(cfg.model_dir, exist_ok=True)
    out = os.path.join(cfg.model_dir, "model.joblib")
    joblib.dump(artifact, out, compress=3)
    print(f"[train] wrote {out} (size={os.path.getsize(out)} bytes)",
          flush=True)

    # Tiny sanity print: top-3 neighbours of book id 1.
    sample = neighbours.get(1, [])[:3]
    print(f"[train] sample: neighbours(book_id=1) top-3 = "
          f"{json.dumps(sample)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
