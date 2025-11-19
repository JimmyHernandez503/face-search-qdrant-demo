# face-search-qdrant-demo

Demo **end-to-end** de búsqueda de rostros usando:

- **FastAPI** + HTML sencillo para subir una foto y buscar similares  
- **InsightFace** (GPU, `onnxruntime-gpu`) para embeddings faciales (512-D)  
- **Qdrant** como base de datos vectorial (cosine similarity)  
- Ingesta incremental de millones de fotos con **SQLite** y thumbnails persistentes

Internamente el proyecto se llama **“infierno” / “oceano4”**, pero está empaquetado como un demo genérico de búsqueda facial con Qdrant.

---

## 1. Arquitectura

Componentes principales:

- **Servicio API (`api`)**
  - Imagen Docker basada en `nvidia/cuda:*` con Python, FastAPI y InsightFace.
  - Endpoints:
    - `GET /` → formulario HTML para subir foto.
    - `POST /search` → recibe una imagen, extrae el embedding del mejor rostro y consulta Qdrant (top-10).
    - `GET /healthz` → healthcheck rápido.
    - `GET /status` → estado de la colección (nombre, número de vectores, status en Qdrant).
  - Expone:
    - **Puerto host 9000 → contenedor 7860**

- **Qdrant (`qdrant`)**
  - Contenedor oficial `qdrant/qdrant:v1.9.1`.
  - Distancia: `cosine`, dimensión: **512**.
  - Expone:
    - **Puerto host 9001 → 6333 (HTTP)**
    - **Puerto host 9002 → 6334 (gRPC)**
  - Persiste datos en `./qdrant_storage`.

- **Ingesta (`app.ingest`)**
  - Script Python (`app/app/ingest.py`) que:
    - Recorre recursivamente una carpeta de imágenes.
    - Calcula embedding con InsightFace (`embed_path`).
    - Crea/actualiza colección en Qdrant.
    - Genera **thumbnails** persistentes en `THUMBS_DIR` (por defecto `./thumbs`).
    - Lleva un registro en **SQLite**:
      - Tabla `files(path, mtime, status, point_id, error)`.
      - Permite **resume** automático (solo procesa cambios nuevos).

- **Embeddings (`app.embeddings`)**
  - Usa `insightface.app.FaceAnalysis` con:
    - Modelo configurable: `MODEL_NAME` (por defecto `buffalo_s`).
    - Carpeta de modelos: `INSIGHTFACE_MODELS` (por defecto `/models`).
    - `MAX_SIDE` / `DOWNSCALE_TO` para limitar tamaño de entrada.
  - Selecciona el **rostro más grande** de la imagen como “mejor rostro”.
  - Devuelve embedding normalizado (`512-D float32`) + bounding box.

- **Front-end (templates)**
  - `templates/index.html` + `static/style.css`.
  - Interfaz minimalista oscuro:
    - Formulario para subir foto.
    - Tabla con resultados (`% similitud`, DUI, thumbnail, ruta de archivo, ID).

---

## 2. Requisitos

### Hardware / SO

- Host Linux (probado en **Ubuntu 24.04.3 LTS**).
- **GPU NVIDIA** con drivers correctos.
- Al menos ~6 GB VRAM recomendados (ej. RTX 3060 6GB).

### Software

- **Docker** + **Docker Compose plugin**.
- **NVIDIA Container Toolkit** (`nvidia-ctk`) para exponer la GPU al contenedor.
- Conexión a Internet la primera vez (para descargar imágenes Docker y modelos).

---

## 3. Estructura del repositorio

```text
.
├── app/
│   ├── requirements.txt      # Dependencias Python del servicio API/ingesta
│   └── app/
│       ├── __init__.py
│       ├── main.py           # FastAPI + endpoints + lógica de búsqueda
│       ├── embeddings.py     # InsightFace, lectura de imágenes y embeddings
│       ├── ingest.py         # Ingesta incremental + SQLite + thumbnails + Qdrant
│       ├── static/
│       │   └── style.css     # Estilos de la UI
│       └── templates/
│           └── index.html    # UI HTML (formulario + tabla de resultados)
├── docker-compose.yml        # Orquestación API + Qdrant (GPU)
├── Dockerfile                # Imagen API (CUDA + FastAPI + InsightFace)
├── setup_infierno.sh         # Instalación “1 click” en Ubuntu con GPU
├── ingest_folder.sh          # Ingesta de una carpeta del host dentro del contenedor
├── ingest_stats.sh           # Estadísticas básicas de ingesta (SQLite)
├── status.sh                 # Estado rápido de docker compose + /status
├── backup_infierno.sh        # Backup completo (código + datos + checksums)
├── make_portable_infierno.sh # Utilidades para versión portable
└── export_github_zip.sh      # Genera ZIP solo con código/config (sin datos pesados)
```

---

## 4. Instalación rápida (Ubuntu + GPU)

> **Advertencia:** `setup_infierno.sh` instala Docker, NVIDIA Container Toolkit, crea `docker-compose.yml` y `Dockerfile` en el directorio. Úsalo en un host dedicado o sabiendo lo que hace.

```bash
# Clonar repo
git clone https://github.com/JimmyHernandez503/face-search-qdrant-demo.git
cd face-search-qdrant-demo

# Dar permisos a los scripts
chmod +x setup_infierno.sh ingest_folder.sh ingest_stats.sh status.sh backup_infierno.sh

# Ejecutar instalación "1 click"
./setup_infierno.sh
```

El script:

1. Borra restos de instalaciones viejas de Docker (opcional).
2. Instala **Docker CE oficial** (`get.docker.com`).
3. Instala y configura **NVIDIA Container Toolkit** (`nvidia-ctk runtime configure`).
4. Genera `docker-compose.yml` y `Dockerfile` (API + Qdrant).
5. Hace `docker compose up -d` levantando:
   - `infierno-qdrant` (Qdrant)
   - `infierno-api` (FastAPI + InsightFace)

Una vez termine:

- API: <http://localhost:9000/>
- Estado API/Qdrant: <http://localhost:9000/status>

---

## 5. Instalación manual (Docker Compose)

Si ya tienes Docker + NVIDIA Toolkit:

```bash
git clone https://github.com/JimmyHernandez503/face-search-qdrant-demo.git
cd face-search-qdrant-demo

# Revisa/ajusta docker-compose.yml y Dockerfile si lo necesitas

docker compose up -d --build
```

Puertos y volúmenes por defecto (`docker-compose.yml`):

- **API**
  - `9000:7860`
  - Volúmenes:
    - `./logs:/logs`
    - `./state:/state` (SQLite)
    - `./thumbs:/data/thumbs` (thumbnails)
    - `./models:/models` (modelos InsightFace)
    - `${HOME}:/hosthome` (home del host dentro del contenedor)

- **Qdrant**
  - `9001:6333` (HTTP)
  - `9002:6334` (gRPC)
  - `./qdrant_storage:/qdrant/storage`

---

## 6. Ingesta de imágenes

> Sin ingesta **no habrá resultados**: primero llena la colección de Qdrant con tus fotos.

### 6.1. Asumiendo carpeta de fotos en el host

La carpeta debe colgar de tu `$HOME`, por ejemplo:

```bash
/home/user2025/Documentos/fotos_personas/
```

Ejemplo de uso:

```bash
# Desde la raíz del repo
./ingest_folder.sh "/home/user2025/Documentos/fotos_personas"
```

El script:

1. Comprueba que `qdrant` está levantado (`docker compose up -d qdrant`).
2. Mapea `$HOME` del host a `/hosthome` dentro del contenedor.
3. Convierte la ruta del host a `/hosthome/...` (`CONTAINER_PATH`).
4. Ejecuta dentro del servicio `api`:

   ```bash
   python3 -m app.ingest --path /hosthome/Documentos/fotos_personas
   ```

Puedes pasar opciones extra a `ingest.py`:

```bash
# Forzar reprocesar todo (ignora SQLite)
./ingest_folder.sh "/home/user2025/Documentos/fotos_personas" --no-resume

# Cambiar tamaño de batch
./ingest_folder.sh "/home/user2025/Documentos/fotos_personas" --batch 512
```

### 6.2. Comportamiento de la ingesta

- Crea/usa una **BD SQLite** en `./state/ingestion.db`.
- Por cada archivo:
  - Verifica si es imagen (`.jpg`, `.jpeg`, `.png`, `.bmp`, `.webp`).
  - Obtiene `dui` del nombre del archivo (todo antes del punto).
  - Calcula embedding con InsightFace.
  - Genera **UUID** como `point_id`.
  - Inserta en Qdrant con payload, típicamente:

    ```json
    {
      "dui": "01234567-8",
      "path": "/hosthome/Documentos/fotos_personas/01234567-8.jpg",
      "thumb_id": "e7ad0f96-....-....-....-........"
    }
    ```

  - Crea thumbnail persistente en `THUMBS_DIR` (por defecto `/data/thumbs`).

- Guarda en SQLite:
  - `status = 'done' | 'pending' | 'error'`
  - `error` con la excepción si algo falla (sin bloquear el resto).

### 6.3. Ver estadísticas de ingesta

```bash
./ingest_stats.sh
```

Muestra con `sqlite3`:

- Número total de archivos.
- Conteo por estado (`done`, `pending`, `error`).

---

## 7. Uso de la interfaz web

Una vez API + Qdrant + ingesta están listos:

1. Abre en el navegador: **<http://localhost:9000/>**
2. Verás un formulario:

   - “Sube una foto (rostro)”
   - Botón **“Buscar top-10”**

3. Sube una imagen con un rostro.
4. El backend:
   - Lee la imagen con OpenCV.
   - Extrae el mejor rostro con InsightFace.
   - Realiza un `search` en Qdrant:
     - colección `COLLECTION_NAME` (por defecto `faces`).
     - métrica `cosine`.
     - `limit = 10`.

5. La tabla de resultados muestra:

   - **Similitud (%)** → `score * 100`, donde `score` es `cosine similarity` (1.0 = 100%).
   - **DUI** (si el nombre de archivo lo contenía).
   - **Thumbnail** → recorte de rostro (si existe en `/thumbs`).
   - **Ruta** → path completo al archivo original.
   - **ID** (UUID de Qdrant).

Si no se detecta ningún rostro, el template muestra un mensaje de error:  
`"No se detectó rostro en la imagen cargada."`

---

## 8. Variables de entorno importantes

### API (`app.main`)

- `QDRANT_URL`  
  URL HTTP de Qdrant (por defecto `http://localhost:6333` o `http://qdrant:6333` en docker-compose).

- `COLLECTION_NAME`  
  Nombre de la colección en Qdrant (`faces` por defecto).

- `THUMBS_DIR`  
  Directorio de thumbnails (`/data/thumbs` por defecto, mapeado a `./thumbs` en el host).

### Ingesta (`app.ingest`)

- `QDRANT_URL`  
- `COLLECTION_NAME`
- `SQLITE_DB` (por defecto `/state/ingestion.db`)
- `THUMBS_DIR` (por defecto `/data/thumbs`)
- `QUANTIZATION`  
  - `"none"` (por defecto)  
  - `"scalar"` → activa `ScalarQuantization` INT8 en Qdrant para ahorrar RAM.

### Embeddings (`app.embeddings`)

- `INSIGHTFACE_MODELS` → `/models` por defecto.
- `MODEL_NAME` → `buffalo_s` por defecto.
- `DET_SIZE` → `"512,512"` por defecto.
- `MAX_SIDE` / `DOWNSCALE_TO` → control de tamaño máximo de la imagen.

---

## 9. Scripts auxiliares

- `setup_infierno.sh`  
  Instalación completa en host Ubuntu (Docker + NVIDIA + docker-compose + Dockerfile).

- `ingest_folder.sh`  
  Lanza ingesta de una carpeta del host desde fuera del contenedor.

- `ingest_stats.sh`  
  Muestra stats básicas de la BD de ingesta.

- `status.sh`  
  - `docker compose ps`
  - `curl http://localhost:9000/status`
  - Últimas 50 líneas de logs del servicio `api`.

- `backup_infierno.sh`  
  Crea `backup/infierno_backup_YYYYMMDD_HHMMSS.tgz` con:
  - Código del proyecto.
  - `state/`, `thumbs/`, `qdrant_storage/`, etc.
  - Fichero `checksums.*.sha256` con `sha256sum`.

- `make_portable_infierno.sh`  
  Scripts/utilidades para parchar rutas, preparar versión portable, etc.

- `export_github_zip.sh`  
  Genera un ZIP listo para subir a GitHub, excluyendo datos pesados (`qdrant_storage`, `thumbs`, `logs`, etc.).

---

## 10. Notas y limitaciones

- Está pensado como **demo/lab** de búsqueda facial con Qdrant, no como producto final.
- Asume **una persona principal por imagen** (se usa el rostro más grande).
- No incluye gestión de usuarios/roles ni autenticación.
- Los modelos de InsightFace **no están en el repo**:
  - Se descargan automáticamente la primera vez bajo `/models`.
  - Puedes precargar otros modelos en esa carpeta.

---

## 11. Licencia

Añade aquí la licencia que prefieras (MIT, Apache 2.0, etc.).  
Por ahora, trátalo como ejemplo educativo / demo de referencia.
