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
