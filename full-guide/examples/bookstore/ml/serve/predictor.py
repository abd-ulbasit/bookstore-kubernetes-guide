"""
Bookstore recommendations — CPU serving predictor (Part 12 ch.06, X3b).

A tiny FastAPI app that loads the `model.joblib` produced by
`../train/train.py` and serves recommendations over HTTP. The training and
serving sides agree on a single, documented artifact shape so the train ->
joblib -> serve loop is genuinely end-to-end runnable on CPU/kind.

Endpoints
---------
GET  /healthz                            -> 200 once the model is loaded
GET  /ready                              -> 200 once the model is loaded
GET  /v1/models/recommender              -> model metadata (KServe-shaped)
POST /v1/models/recommender:predict      -> top-K recommendations for book_id
GET  /recommend?book_id=<id>&k=<k>       -> friendly equivalent (catalog uses)

The :predict body follows the v1 prediction protocol used by KServe-style
runtimes (sklearn, pytorch, tensorflow, huggingface) — a small JSON envelope
with `instances` — so the same surface works whether this image is run as a
plain Deployment OR as a KServe `InferenceService` `predictor` (Part 12 ch.06).

Request:
  {"instances": [{"book_id": 1, "k": 5}, ...]}

Response:
  {"predictions": [{"book_id": 1, "k": 5,
                    "recommendations": [{"book_id": 17, "score": 0.81,
                                          "title": "...", "author": "..."},
                                         ...]}, ...]}
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import joblib
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

log = logging.getLogger("recommender")
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

MODEL_DIR = os.environ.get("MODEL_DIR", "/workspace/model")
MODEL_NAME = os.environ.get("MODEL_NAME", "recommender")
DEFAULT_K = int(os.environ.get("DEFAULT_K", "5"))


# ----- Model wrapper -------------------------------------------------------

class Model:
    """Wraps the joblib artifact produced by ../train/train.py."""

    def __init__(self, path: str):
        log.info("loading model artifact from %s", path)
        artifact = joblib.load(path)
        self.kind = artifact["kind"]
        self.version = artifact["version"]
        self.n_books = artifact["n_books"]
        self.top_k = artifact["top_k"]
        self.neighbours: dict[int, list] = artifact["neighbours"]
        self.books_index: dict[int, dict] = artifact["books_index"]
        log.info("model loaded kind=%s version=%s n_books=%d top_k=%d",
                 self.kind, self.version, self.n_books, self.top_k)

    def recommend(self, book_id: int, k: int) -> list[dict[str, Any]]:
        neigh = self.neighbours.get(int(book_id))
        if neigh is None:
            return []
        k = max(1, min(k, len(neigh)))
        out: list[dict[str, Any]] = []
        for nb_id, score in neigh[:k]:
            meta = self.books_index.get(int(nb_id), {})
            out.append({
                "book_id": int(nb_id),
                "score": float(score),
                "title": meta.get("title"),
                "author": meta.get("author"),
            })
        return out

    def metadata(self) -> dict[str, Any]:
        return {
            "name": MODEL_NAME,
            "kind": self.kind,
            "version": self.version,
            "n_books": self.n_books,
            "top_k": self.top_k,
        }


_MODEL: Model | None = None


def get_model() -> Model:
    global _MODEL
    if _MODEL is None:
        _MODEL = Model(os.path.join(MODEL_DIR, "model.joblib"))
    return _MODEL


# ----- HTTP API ------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    get_model()  # surface load errors immediately
    yield


app = FastAPI(title="bookstore-recommender", version="1", lifespan=lifespan)


class PredictInstance(BaseModel):
    book_id: int = Field(..., ge=1)
    k: int = Field(default=DEFAULT_K, ge=1, le=100)


class PredictRequest(BaseModel):
    instances: list[PredictInstance]


@app.get("/healthz")
def healthz() -> dict[str, str]:
    get_model()
    return {"status": "ok"}


@app.get("/ready")
def ready() -> dict[str, str]:
    get_model()
    return {"status": "ready"}


@app.get("/v1/models/recommender")
def model_meta() -> dict[str, Any]:
    return get_model().metadata()


@app.post("/v1/models/recommender:predict")
def predict(body: PredictRequest) -> dict[str, Any]:
    m = get_model()
    preds = []
    for inst in body.instances:
        preds.append({
            "book_id": inst.book_id,
            "k": inst.k,
            "recommendations": m.recommend(inst.book_id, inst.k),
        })
    return {"predictions": preds}


@app.get("/recommend")
def recommend(
    book_id: int = Query(..., ge=1),
    k: int = Query(DEFAULT_K, ge=1, le=100),
) -> dict[str, Any]:
    """Friendly handle for the `catalog`/`storefront` services."""
    m = get_model()
    recs = m.recommend(book_id, k)
    if not recs and book_id > m.n_books:
        raise HTTPException(status_code=404, detail="book_id out of range")
    return {"book_id": book_id, "k": k, "recommendations": recs}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        app,
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8080")),
        log_level=os.environ.get("LOG_LEVEL", "info").lower(),
    )
