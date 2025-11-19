#!/usr/bin/env bash
set -euo pipefail

BASE="/home/user2025/infierno"
APP="$BASE/app"

echo "[1/6] Quitar 'version:' del compose para eliminar el warning (opcional)..."
if grep -qE '^[[:space:]]*version:' "$BASE/docker-compose.yml"; then
  sed -i '/^[[:space:]]*version:/d' "$BASE/docker-compose.yml"
  echo "  -> 'version:' removido de docker-compose.yml"
else
  echo "  -> No había 'version:' en docker-compose.yml"
fi

echo "[2/6] Dockerfile -> cambiar a CUDA 11.8 (provee libcublasLt.so.11)..."
cat > "$BASE/Dockerfile" <<'DOCKER'
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv git \
    libgl1 libglib2.0-0 && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip

WORKDIR /app
COPY ./app/requirements.txt /app/requirements.txt
RUN pip3 install --no-cache-dir -r /app/requirements.txt

# Directorios persistentes
RUN mkdir -p /logs /state /data/thumbs /models

# Copiamos el código
COPY ./app /app

EXPOSE 7860
CMD ["sh", "-lc", "python3 -m uvicorn app.main:app --host ${UVICORN_HOST:-0.0.0.0} --port ${UVICORN_PORT:-7860} --log-level info"]
DOCKER
echo "  -> Dockerfile actualizado a CUDA 11.8"

echo "[3/6] requirements.txt -> fijar onnxruntime-gpu a 1.16.3 (CUDA 11.x) ..."
cat > "$APP/requirements.txt" <<'REQ'
# Servidor API
fastapi==0.115.5
uvicorn[standard]==0.30.6
jinja2==3.1.4
aiofiles==23.2.1
python-multipart==0.0.9

# Cliente vector DB
qdrant-client==1.8.2

# Embeddings faciales (GPU)
insightface==0.7.3
onnxruntime-gpu==1.16.3

# Utilidades
opencv-python-headless==4.10.0.84
numpy==1.26.4
pillow==10.4.0
tqdm==4.66.5
rich==13.8.1
orjson==3.10.7
REQ
echo "  -> requirements.txt actualizado"

echo "[4/6] Cambiar IDs a UUID (Qdrant) y mantener SHA1 para thumbnails..."
# --- app/ingest.py ---
cat > "$APP/app/ingest.py" <<'PY'
import os
import time
import sqlite3
import argparse
import uuid
from pathlib import Path
from typing import List, Tuple, Optional
from tqdm import tqdm
from rich import print as rprint
from PIL import Image

import numpy as np
from qdrant_client import QdrantClient
from qdrant_client.http.models import (
    VectorParams, Distance, PointStruct, OptimizersConfigDiff, ScalarQuantization, ScalarType
)

from .embeddings import embed_path

QDRANT_URL = os.getenv("QDRANT_URL", "http://localhost:6333")
COLLECTION = os.getenv("COLLECTION_NAME", "faces")
SQLITE_DB = os.getenv("SQLITE_DB", "/state/ingestion.db")
THUMBS_DIR = os.getenv("THUMBS_DIR", "/data/thumbs")
QUANTIZATION = os.getenv("QUANTIZATION", "none").lower()  # none | scalar

def ensure_sqlite():
    Path(SQLITE_DB).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(SQLITE_DB)
    conn.execute("""
    CREATE TABLE IF NOT EXISTS files (
      path TEXT PRIMARY KEY,
      mtime REAL NOT NULL,
      status TEXT NOT NULL,
      point_id TEXT,
      error TEXT
    )
    """)
    conn.commit()
    return conn

def sha1_of(text: str) -> str:
    import hashlib
    return hashlib.sha1(text.encode("utf-8")).hexdigest()

def is_image(p: Path) -> bool:
    return p.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

def get_dui_from_name(p: Path) -> Optional[str]:
    # Espera nombres tipo 01234567-8.jpg
    return p.name.rsplit(".", 1)[0]

def ensure_collection(client: QdrantClient):
    if not client.collection_exists(collection_name=COLLECTION):
        rprint(f"[yellow]Creando colección '{COLLECTION}' en Qdrant…[/yellow]")
        client.recreate_collection(
            collection_name=COLLECTION,
            vectors_config=VectorParams(size=512, distance=Distance.COSINE),
            optimizers_config=OptimizersConfigDiff(
                memmap_threshold=20000,
                indexing_threshold=20000
            )
        )
        if QUANTIZATION == "scalar":
            client.update_collection(
                collection_name=COLLECTION,
                quantization_config=ScalarQuantization(
                    scalar=ScalarType.INT8, always_ram=False
                )
            )
    else:
        rprint(f"[green]Colección '{COLLECTION}' OK.[/green]")

def make_thumb(src_path: str, dst_path: str):
    try:
        im = Image.open(src_path).convert("RGB")
        im.thumbnail((160,160))
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        im.save(dst_path, "JPEG", quality=85)
    except Exception:
        pass

def batch_upsert(client: QdrantClient, batch: List[Tuple[str, str, str, np.ndarray]]):
    # batch: [(uuid_str, thumb_id, path, emb), ...]
    points = []
    for uid, thumb_id, path, emb in batch:
        dui = get_dui_from_name(Path(path)) or ""
        payload = {"dui": dui, "path": path, "thumb_id": thumb_id}
        points.append(PointStruct(id=uid, vector=emb.tolist(), payload=payload))
    client.upsert(collection_name=COLLECTION, points=points)

def scan_paths(root: str) -> List[Path]:
    p = Path(root)
    if p.is_file() and is_image(p):
        return [p]
    return [pp for pp in p.rglob("*") if pp.is_file() and is_image(pp)]

def process(root: str, batch_size: int = 256, resume: bool = True):
    client = QdrantClient(url=QDRANT_URL, timeout=600)
    ensure_collection(client)
    conn = ensure_sqlite()
    cur = conn.cursor()

    paths = scan_paths(root)
    rprint(f"[cyan]Archivos de imagen detectados en '{root}': {len(paths)}[/cyan]")

    batch: List[Tuple[str, str, str, np.ndarray]] = []
    with tqdm(total=len(paths), desc="Ingestando", unit="img") as pbar:
        for p in paths:
            pbar.update(1)
            path = str(p)
            mtime = p.stat().st_mtime
            thumb_id = sha1_of(f"{path}:{mtime}")       # para thumbnails
            # UUID determinístico (evita duplicados y cumple con Qdrant)
            uid = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{path}:{mtime}"))

            if resume:
                row = cur.execute("SELECT status FROM files WHERE path=?", (path,)).fetchone()
                if row and row[0] == "done":
                    continue

            emb = embed_path(path)
            if emb is None:
                cur.execute("REPLACE INTO files(path, mtime, status, point_id, error) VALUES (?,?,?,?,?)",
                            (path, mtime, "error", None, "no_face"))
                conn.commit()
                continue

            # thumbnail persistente por thumb_id
            thumb_path = os.path.join(THUMBS_DIR, f"{thumb_id}.jpg")
            if not os.path.exists(thumb_path):
                make_thumb(path, thumb_path)

            batch.append((uid, thumb_id, path, emb))
            cur.execute("REPLACE INTO files(path, mtime, status, point_id, error) VALUES (?,?,?,?,?)",
                        (path, mtime, "pending", uid, None))

            if len(batch) >= batch_size:
                batch_upsert(client, batch)
                for _, _, path_i, _ in batch:
                    cur.execute("UPDATE files SET status='done' WHERE path=?", (path_i,))
                conn.commit()
                batch.clear()

        if batch:
            batch_upsert(client, batch)
            for _, _, path_i, _ in batch:
                cur.execute("UPDATE files SET status='done' WHERE path=?", (path_i,))
            conn.commit()

    rprint("[green]Ingesta finalizada.[/green]")

def main():
    ap = argparse.ArgumentParser(description="Ingesta incremental (GPU embeddings + Qdrant, UUID IDs)")
    ap.add_argument("--path", required=True, help="Directorio o archivo de imágenes (recursivo)")
    ap.add_argument("--batch", type=int, default=256, help="Tamaño de lote para upsert")
    ap.add_argument("--no-resume", action="store_true", help="Ignorar estado y reprocesar todo")
    args = ap.parse_args()
    process(root=args.path, batch_size=args.batch, resume=(not args.no_resume))

if __name__ == "__main__":
    main()
PY

# --- app/main.py ---
cat > "$APP/app/main.py" <<'PY'
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

app = FastAPI(title="infierno - Reconocimiento Facial")

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
PY
echo "  -> Código actualizado (UUID + thumb_id)."

echo "[5/6] Rebuild de la imagen y levantar servicios..."
cd "$BASE"
docker compose build --no-cache api
docker compose up -d

echo "[6/6] Comprobaciones útiles:"
echo " - Proveedores ONNX dentro del contenedor (debe incluir CUDAExecutionProvider):"
echo "   docker exec -it infierno-api python3 -c \"import onnxruntime as ort; print(ort.get_available_providers())\""
echo " - Estado API/Qdrant:"
echo "   $BASE/status.sh"
echo " - Ingesta de prueba:"
echo "   $BASE/ingest_folder.sh \"/home/user2025/Descargas/04/00/00\""
