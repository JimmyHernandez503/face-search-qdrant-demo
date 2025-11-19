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
