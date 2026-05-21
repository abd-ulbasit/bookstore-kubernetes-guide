# Bookstore ML dataset — shape (synthetic, generated, NOT shipped)

The recommendations model (Part 12) trains on the Bookstore's own data. **No
data file is committed here.** This document is the *spec* for the (synthetic)
training data: which Bookstore tables it derives from, and the
item-co-occurrence matrix the training step builds from them. The training Job
in **X3b** generates the synthetic source rows and produces the matrix; this
phase (X3a) only fixes the shape so ch.03's gang-scheduled "training" demo and
X3b's real training agree.

## Source: the real Bookstore schema

The app's schema (from [`../../app/catalog/main.go`](../../app/catalog/main.go)
and [`../../app/orders/main.go`](../../app/orders/main.go), created by the
migration Job in
[Part 01 ch.07](../../../../01-core-workloads/07-jobs-and-cronjobs.md)):

```
books   (id SERIAL PK, title TEXT, author TEXT, price NUMERIC)
orders  (id SERIAL PK, book_id INT, qty INT, created_at TIMESTAMPTZ)
```

`orders` has **no explicit basket/customer column** (the app posts one
`{book_id, qty}` per order). So the recommender uses a documented, deliberately
simple **basket proxy**: orders are grouped into pseudo-baskets by a synthetic
`customer_id` (assigned by the generator) — equivalently, a time-window or
modulo grouping over `created_at`/`id`. This is *good enough for a teaching
recommender* and is stated honestly; a production system would carry a real
basket/session id.

## Synthetic generation (done by the X3b training Job, not here)

- ~50–500 synthetic books (id, title, author, price) consistent with the
  catalog shape.
- ~1k–50k synthetic `orders` rows assigned to ~N synthetic customers/baskets,
  with mild popularity skew and a few planted "bought together" affinities so
  the learned neighbours are non-trivial.
- Fully deterministic given a fixed **seed** (pinned in the training Job's
  config) — so the dataset, and therefore the model, is **reproducible** (the
  Part 12 ch.01 reproducibility requirement). Tiny by design → trains in
  seconds, CPU-only, on kind.

## Derived artifact: the item co-occurrence matrix

The training step (CPU, NumPy/scikit-learn-class):

1. Build a sparse **customer × book** interaction matrix from the (synthetic)
   `orders` grouped by the basket proxy.
2. Compute the **book × book co-occurrence** matrix (interaction-matrix
   self-product) and normalise it (cosine / Jaccard) into an item-similarity
   matrix.
3. Keep the **top-K neighbours per book** (K small, e.g. 10).

```
 orders (synthetic)        customer × book           book × book           top-K per book
 ┌────────────────┐        (sparse, 0/qty)           similarity             (the MODEL)
 │ cust  book qty  │  ─►   ┌───────────────┐  ─►    ┌──────────────┐  ─►   { book_id:
 │  c1    b2   1   │       │ c1: b2,b7      │        │ b2: b7 .82,  │         [ (b7,.82),
 │  c1    b7   1   │       │ c2: b2,b9 …    │        │     b9 .31 … │           (b9,.31) ],
 │  c2    b2   2   │       └───────────────┘        └──────────────┘          … }
 └────────────────┘
```

The serving artifact (X3b) is just this top-K map (JSON / a small binary)
loaded by the recommendations API: `GET /recommend?book_id=<ID>` → the top-K
co-bought `book_id`s. Small enough to fit in a ConfigMap-or-PVC and serve from
a tiny CPU Deployment — and large enough that ch.02/03 can *honestly* use it as
the "scale training up onto a GPU" example without faking anything.

## Why generated, not shipped

- Keeps the repo free of a binary/data blob and keeps the example
  **reproducible from a seed** (re-generate, get the identical model).
- The shape is stable and small so ch.03's 2-worker gang "training" and X3b's
  real training operate on the same contract without a GPU.
