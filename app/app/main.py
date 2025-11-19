import os
from pathlib import Path
from typing import List, Dict

from fastapi import FastAPI, File, UploadFile, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import numpy as np
from qdrant_client import QdrantClient
import cv2

from .embeddings import best_face_embedding

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
COLLECTION = os.getenv("COLLECTION_NAME", "faces")
THUMBS_DIR = os.getenv("THUMBS_DIR", "/data/thumbs")

app = FastAPI(title="oceano4 - Reconocimiento Facial")

app.mount("/static", StaticFiles(directory=str(Path(__file__).parent / "static")), name="static")
app.mount("/thumbs", StaticFiles(directory=THUMBS_DIR), name="thumbs")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

_client = QdrantClient(url=QDRANT_URL, timeout=600)

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/status")
def status():
    try:
        c = _client.get_collection(COLLECTION)
        count = _client.count(COLLECTION, exact=False).count
        return {"collection": COLLECTION, "vectors": count, "status": c.status.value}
    except Exception as e:
        return {"error": str(e)}

@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/search", response_class=HTMLResponse)
async def search(request: Request, file: UploadFile = File(...)):
    data = await file.read()
    arr = np.frombuffer(data, dtype=np.uint8)
    img = cv2.imdecode(arr, cv2.IMREAD_COLOR)

    out = best_face_embedding(img)
    if out is None:
        return templates.TemplateResponse("index.html", {
            "request": request,
            "error": "No se detectó rostro en la imagen cargada."
        })

    emb, _ = out
    res = _client.search(
        collection_name=COLLECTION,
        query_vector=emb.tolist(),
        limit=10,
        with_payload=["dui", "path", "thumb_id"]
    )

    items: List[Dict] = []
    for p in res:
        pid = str(p.id)  # UUID
        payload = p.payload or {}
        dui = payload.get("dui", "")
        path = payload.get("path", "")
        thumb_id = payload.get("thumb_id", pid)  # fallback al id si viniera vacío
        score = float(p.score)  # cosine similarity, mayor=mejor
        percent = round(score * 100.0, 2)
        thumb = f"/thumbs/{thumb_id}.jpg" if Path(THUMBS_DIR, f"{thumb_id}.jpg").exists() else None
        items.append({"percent": percent, "dui": dui, "path": path, "pid": pid, "thumb": thumb})

    return templates.TemplateResponse("index.html", {"request": request, "items": items})
