#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  infierno - Reconocimiento facial (GPU + Qdrant) - Instalación 1-click
#  Host: Ubuntu 24.04.3 LTS | GPU: RTX 3060 (6GB VRAM)
#  Este script limpia conflictos de Docker, instala Docker CE oficial,
#  configura NVIDIA Toolkit y despliega la app (API+Qdrant) con GPU.
# =========================================================

# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$BASE/app"
LOGS="$BASE/logs"
STATE="$BASE/state"
THUMBS="$BASE/thumbs"
QDRANT="$BASE/qdrant_storage"

mkdir -p "$APP" "$LOGS" "$STATE" "$THUMBS" "$QDRANT"

echo "[1/10] Paquetes base y utilidades..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release jq sqlite3

echo "[2/10] LIMPIEZA de paquetes Docker en conflicto (si existen)..."
# Quitamos cualquier instalación previa para evitar containerd/containerd.io conflicts
sudo systemctl stop docker || true
sudo apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc || true
sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
sudo apt-get autoremove -y || true
sudo rm -rf /var/lib/docker /var/lib/containerd || true

echo "[3/10] Instalando Docker CE oficial (get.docker.com)..."
# Instala docker-ce, docker-ce-cli, containerd.io, buildx y compose plugin oficiales
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh

echo "[4/10] Verificando Docker..."
docker --version
docker compose version || true

echo "[5/10] NVIDIA Container Toolkit (para exponer GPU a Docker)..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[!] No se detectó 'nvidia-smi'. Intentando instalar driver 550..."
  sudo apt-get install -y nvidia-driver-550 || true
  echo "[i] Si no funciona, instala el driver recomendado por Ubuntu y vuelve a ejecutar este script."
fi

# Instala toolkit (si el repo ya está configurado, esto solo instalará el paquete)
sudo apt-get update -y
sudo apt-get install -y nvidia-container-toolkit || true
sudo nvidia-ctk runtime configure --runtime=docker || true
sudo systemctl restart docker || true

echo "[6/10] Creando docker-compose.yml..."
cat > "$BASE/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  qdrant:
    image: qdrant/qdrant:v1.9.1
    container_name: infierno-qdrant
    restart: unless-stopped
    environment:
      QDRANT__STORAGE__ON_DISK: "true"
      QDRANT__SERVICE__GRPC_PORT: "6334"
    volumes:
      - ./qdrant_storage:/qdrant/storage
    ports:
      - "6333:6333"
      - "6334:6334"

  api:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: infierno-api
    restart: unless-stopped
    environment:
      QDRANT_URL: "http://qdrant:6333"
      COLLECTION_NAME: "faces"
      THUMBS_DIR: "/data/thumbs"
      SQLITE_DB: "/state/ingestion.db"
      INSIGHTFACE_MODELS: "/models"
      UVICORN_HOST: "0.0.0.0"
      UVICORN_PORT: "7860"
      QUANTIZATION: "none"        # cambia a "scalar" si necesitas bajar RAM
      MODEL_NAME: "buffalo_s"     # modelo ligero recomendado para empezar
      DET_SIZE: "512,512"         # detector más chico = menos VRAM/tiempo
      MAX_SIDE: "1400"            # si la imagen supera esto, se reescala
      DOWNSCALE_TO: "1024"
    volumes:
      - ./logs:/logs
      - ./state:/state
      - ./thumbs:/data/thumbs
      - ./app:/app
    ports:
      - "7860:7860"
    gpus: all
    depends_on:
      - qdrant
YAML

echo "[7/10] Creando Dockerfile (API con CUDA y deps estables)..."
cat > "$BASE/Dockerfile" <<'DOCKER'
FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

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

echo "[8/10] requirements.txt (versiones sin conflictos)..."
mkdir -p "$APP"
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
onnxruntime-gpu==1.18.0

# Utilidades
opencv-python-headless==4.10.0.84
numpy==1.26.4
pillow==10.4.0
tqdm==4.66.5
rich==13.8.1
orjson==3.10.7
REQ

echo "[9/10] Código de la app (API + Ingesta + Web)..."
mkdir -p "$APP/app/templates" "$APP/app/static"
cat > "$APP/app/__init__.py" <<'PY'
# infierno package
PY

# -------- embeddings.py --------
cat > "$APP/app/embeddings.py" <<'PY'
import os
import cv2
import numpy as np
from typing import Optional, Tuple
from insightface.app import FaceAnalysis

_MODEL = None

def _parse_det_size(val: str):
    try:
        a, b = val.split(",")
        return (int(a), int(b))
    except Exception:
        return (512, 512)

def get_face_app() -> FaceAnalysis:
    """Carga InsightFace con modelo y tamaño de detector desde variables de entorno."""
    global _MODEL
    if _MODEL is None:
        providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
        root = os.environ.get("INSIGHTFACE_MODELS", "/models")
        model_name = os.environ.get("MODEL_NAME", "buffalo_s")
        det_size = _parse_det_size(os.environ.get("DET_SIZE", "512,512"))
        _MODEL = FaceAnalysis(name=model_name, root=root, providers=providers)
        _MODEL.prepare(ctx_id=0, det_size=det_size)
    return _MODEL

def read_image(path: str) -> Optional[np.ndarray]:
    img = cv2.imdecode(np.fromfile(path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        return None
    max_side = int(os.environ.get("MAX_SIDE", "1400"))
    target = int(os.environ.get("DOWNSCALE_TO", "1024"))
    h, w = img.shape[:2]
    m = max(h, w)
    if m > max_side:
        scale = target / float(m)
        img = cv2.resize(img, (int(w*scale), int(h*scale)), interpolation=cv2.INTER_AREA)
    return img

def best_face_embedding(img_bgr: np.ndarray) -> Optional[Tuple[np.ndarray, np.ndarray]]:
    app = get_face_app()
    faces = app.get(img_bgr)
    if not faces:
        return None
    faces.sort(key=lambda f: (f.bbox[2]-f.bbox[0])*(f.bbox[3]-f.bbox[1]), reverse=True)
    f = faces[0]
    emb = f.normed_embedding  # 512-D normalizado
    return emb.astype(np.float32), f.bbox

def embed_path(path: str) -> Optional[np.ndarray]:
    img = read_image(path)
    if img is None:
        return None
    out = best_face_embedding(img)
    if out is None:
        return None
    emb, _ = out
    return emb
PY

# -------- ingest.py --------
cat > "$APP/app/ingest.py" <<'PY'
import os
import time
import sqlite3
import hashlib
import argparse
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
    base = p.name.rsplit(".", 1)[0]
    return base

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
        from PIL import Image
        im = Image.open(src_path).convert("RGB")
        im.thumbnail((160,160))
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        im.save(dst_path, "JPEG", quality=85)
    except Exception:
        pass

def batch_upsert(client: QdrantClient, batch: List[Tuple[str, str, np.ndarray]]):
    points = []
    for pid, path, emb in batch:
        dui = get_dui_from_name(Path(path)) or ""
        payload = {"dui": dui, "path": path}
        points.append(PointStruct(id=pid, vector=emb.tolist(), payload=payload))
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

    batch: List[Tuple[str, str, np.ndarray]] = []
    from tqdm import tqdm
    with tqdm(total=len(paths), desc="Ingestando", unit="img") as pbar:
        for p in paths:
            pbar.update(1)
            path = str(p)
            mtime = p.stat().st_mtime
            pid = sha1_of(f"{path}:{mtime}")

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

            thumb_path = os.path.join(THUMBS_DIR, f"{pid}.jpg")
            if not os.path.exists(thumb_path):
                make_thumb(path, thumb_path)

            batch.append((pid, path, emb))
            cur.execute("REPLACE INTO files(path, mtime, status, point_id, error) VALUES (?,?,?,?,?)",
                        (path, mtime, "pending", pid, None))

            if len(batch) >= batch_size:
                batch_upsert(client, batch)
                for _, path_i, _ in batch:
                    cur.execute("UPDATE files SET status='done' WHERE path=?", (path_i,))
                conn.commit()
                batch.clear()

        if batch:
            batch_upsert(client, batch)
            for _, path_i, _ in batch:
                cur.execute("UPDATE files SET status='done' WHERE path=?", (path_i,))
            conn.commit()

    rprint("[green]Ingesta finalizada.[/green]")

def main():
    ap = argparse.ArgumentParser(description="Ingesta incremental de imágenes (GPU embeddings + Qdrant)")
    ap.add_argument("--path", required=True, help="Directorio o archivo de imágenes (recursivo)")
    ap.add_argument("--batch", type=int, default=256, help="Tamaño de lote para upsert")
    ap.add_argument("--no-resume", action="store_true", help="Ignorar estado y reprocesar todo")
    args = ap.parse_args()
    process(root=args.path, batch_size=args.batch, resume=(not args.no_resume))

if __name__ == "__main__":
    main()
PY

# -------- main.py (API/WEB) --------
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
        with_payload=["dui", "path"]
    )

    items: List[Dict] = []
    for p in res:
        pid = str(p.id)
        dui = (p.payload or {}).get("dui", "")
        path = (p.payload or {}).get("path", "")
        score = float(p.score)  # cosine similarity, mayor=mejor
        percent = round(score * 100.0, 2)
        thumb = f"/thumbs/{pid}.jpg" if Path(THUMBS_DIR, f"{pid}.jpg").exists() else None
        items.append({"percent": percent, "dui": dui, "path": path, "pid": pid, "thumb": thumb})

    return templates.TemplateResponse("index.html", {"request": request, "items": items})
PY

# -------- templates/index.html --------
cat > "$APP/app/templates/index.html" <<'HTML'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>infierno - Reconocimiento facial</title>
  <link rel="stylesheet" href="/static/style.css"/>
</head>
<body>
  <div class="wrap">
    <h1>Oceano4 · Reconocimiento facial</h1>
    <form action="/search" method="post" enctype="multipart/form-data" class="card">
      <label>Sube una foto (rostro):</label>
      <input type="file" name="file" accept="image/*" required />
      <button type="submit">Buscar top-10</button>
    </form>

    {% if error %}
      <div class="error">{{ error }}</div>
    {% endif %}

    {% if items %}
      <h2>Resultados (Top-10)</h2>
      <table>
        <thead>
          <tr>
            <th>Similarity</th>
            <th>DUI</th>
            <th>Vista</th>
            <th>Ruta (host)</th>
          </tr>
        </thead>
        <tbody>
        {% for it in items %}
          <tr>
            <td>{{ it.percent }}%</td>
            <td class="mono">{{ it.dui }}</td>
            <td>
              {% if it.thumb %}
                <img src="{{ it.thumb }}" class="thumb"/>
              {% else %}
                —
              {% endif %}
            </td>
            <td class="path">{{ it.path }}</td>
          </tr>
        {% endfor %}
        </tbody>
      </table>
    {% endif %}

    <div class="muted">
      <p><b>Notas:</b> similitud = <i>cosine similarity</i> (100% = idéntico). Thumbnails se generan en la ingesta.</p>
    </div>
  </div>
</body>
</html>
HTML

# -------- static/style.css --------
cat > "$APP/app/static/style.css" <<'CSS'
body { font-family: system-ui, sans-serif; background:#0b0d12; color:#e7e9ee; margin:0; }
.wrap { max-width: 980px; margin: 24px auto; padding: 0 16px; }
h1 { font-weight: 700; font-size: 22px; margin-bottom: 16px; }
h2 { font-size: 18px; margin-top: 24px; }
.card { background:#111522; padding:16px; border-radius:12px; display:flex; gap:12px; align-items:center; }
.card input[type=file]{ background:#0b0d12; border:1px solid #2a2f42; padding:8px; border-radius:8px; }
.card button{ background:#4f7cff; color:white; border:none; padding:10px 14px; border-radius:10px; cursor:pointer; }
.card button:hover{ opacity:.9; }
.error{ background:#2a1620; color:#ffb4c1; padding:12px; border-radius:10px; margin-top:12px; }
table{ width:100%; border-collapse: collapse; margin-top:10px; }
th, td{ border-bottom: 1px solid #2a2f42; padding:10px; text-align:left; }
.thumb{ width:64px; height:64px; object-fit:cover; border-radius:8px; border:1px solid #2a2f42;}
.mono{ font-family: ui-monospace, Menlo, Consolas, monospace; }
.path{ color:#9aa3b2; font-size:12px; }
.muted{ color:#9aa3b2; font-size: 13px; margin-top: 18px; }
CSS

echo "[10/10] Scripts de ayuda (ingesta, estado, progreso) y despliegue..."

# -------- ingest_folder.sh --------
cat > "$BASE/ingest_folder.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "Uso: $0 /ruta/a/la/carpeta (ej: /home/user2025/Descargas/04/00/00)"
  exit 1
fi
FOLDER="$1"
if [ ! -d "$FOLDER" ] && [ ! -f "$FOLDER" ]; then
  echo "No existe: $FOLDER"
  exit 1
fi
docker compose run --rm --gpus all \
  -v "$FOLDER":"$FOLDER":ro \
  api python3 -m app.ingest --path "$FOLDER" --batch 256
SH
chmod +x "$BASE/ingest_folder.sh"

# -------- status.sh --------
cat > "$BASE/status.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "=== docker compose ps ==="
docker compose ps
echo
echo "=== API /status ==="
STATUS=$(curl -s http://localhost:9002/status || true)
if command -v jq >/dev/null 2>&1; then
  echo "$STATUS" | jq .
else
  echo "$STATUS"
fi
echo
echo "=== Últimas 50 líneas de logs (api) ==="
docker compose logs --tail 50 api || true
SH
chmod +x "$BASE/status.sh"

# -------- ingest_stats.sh --------
cat > "$BASE/ingest_stats.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DB="/home/user2025/infierno/state/ingestion.db"
if [ ! -f "$DB" ]; then
  echo "No existe $DB aún (ingesta no iniciada)."
  exit 0
fi
sqlite3 "$DB" <<'SQL'
.headers on
.mode column
SELECT COUNT(*) AS total FROM files;
SELECT
  SUM(CASE WHEN status='done'    THEN 1 ELSE 0 END) AS done,
  SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) AS pending,
  SUM(CASE WHEN status='error'   THEN 1 ELSE 0 END) AS error
FROM files;
SQL
SH
chmod +x "$BASE/ingest_stats.sh"

# Build & Up
cd "$BASE"
echo "[*] Construyendo imágenes..."
docker compose build --no-cache
echo "[*] Levantando servicios..."
docker compose up -d

echo "[*] Esperando a que la API responda /healthz..."
for i in {1..60}; do
  if curl -sf http://localhost:9002/healthz >/dev/null; then
    echo "API OK en http://localhost:9002"
    break
  fi
  sleep 2
done

echo
echo "=========================================================="
echo "  INSTALACIÓN COMPLETA"
echo "  Web:       http://localhost:9002"
echo "  Qdrant:    http://localhost:6333 (REST)"
echo
echo "  Ingestar carpeta de prueba (recursivo):"
echo "    $BASE/ingest_folder.sh \"/home/user2025/Descargas/04/00/00\""
echo
echo "  Ver progreso y totales:"
echo "    $BASE/ingest_stats.sh"
echo
echo "  Estado y logs:"
echo "    $BASE/status.sh"
echo
echo "Notas:"
echo " - Se eliminaron paquetes Docker en conflicto y se instaló Docker CE oficial."
echo " - Colección 'faces' persistente (no se reconstruye al reiniciar)."
echo " - Ingesta incremental reanudable (SQLite en $STATE/ingestion.db)."
echo " - Thumbnails en $THUMBS para la web."
echo " - Para reducir RAM al escalar, cambia QUANTIZATION a 'scalar' en docker-compose.yml y reinicia."
echo "=========================================================="
