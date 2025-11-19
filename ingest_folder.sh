#!/usr/bin/env bash

# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directorio HOME del host (por defecto, \$HOME del usuario actual)
HOST_HOME="${HOST_HOME:-$HOME}"

set -euo pipefail

# Carpeta base = donde está este script
BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

echo "[DBG] BASE = $BASE"

if [ $# -lt 1 ]; then
  echo "Uso: $0 /ruta/absoluta/a/carpeta_de_fotos [opciones_extra_para_ingest.py]" >&2
  echo "Ejemplo: $0 \"/home/user2025/Documentos/fotos_f\" --no-resume" >&2
  exit 1
fi

SRC="$1"
shift || true

echo "[DBG] SRC (host) = $SRC"

if [ ! -d "$SRC" ]; then
  echo "[ERR] Directorio no existe en el host: $SRC" >&2
  exit 1
fi

# HOME del host
echo "[DBG] HOST_HOME = $HOST_HOME"

if [[ "$SRC" != "$HOST_HOME"* ]]; then
  echo "[ERR] Por ahora la ruta debe colgar de $HOST_HOME para mapearla a /hosthome dentro del contenedor." >&2
  echo "     Ejemplos válidos: /home/user2025/Documentos/..., /home/user2025/Descargas/..., etc." >&2
  exit 1
fi

# Parte relativa respecto a /home/user2025
REL="${SRC#$HOST_HOME}"
CONTAINER_PATH="/hosthome${REL}"

echo "[i] Ingestando carpeta:"
echo "    Host      : $SRC"
echo "    Contenedor: $CONTAINER_PATH"
echo

echo "[DBG] Comprobando que 'docker compose' funciona..."
docker compose version || {
  echo "[ERR] 'docker compose' falló. ¿Está el daemon levantado?" >&2
  exit 1
}

echo "[DBG] Servicios definidos en este docker-compose:"
docker compose ps || true
echo

# Asegurarnos de que Qdrant está arriba
echo "[i] Levantando servicio 'qdrant' (si no lo está)..."
docker compose up -d qdrant

echo "[i] Forzando variables de entorno de Qdrant dentro del contenedor de ingesta..."
echo "    QDRANT_HOST = qdrant"
echo "    QDRANT_PORT = 6333"
echo

echo "[i] Lanzando ingesta dentro del contenedor (servicio 'api')..."
echo "[DBG] Comando completo:"
echo "     docker compose run --rm \\"
echo "        -e QDRANT_URL=http://qdrant:6333 \\"
echo "        -e QDRANT_HOST=qdrant \\"
echo "        -e QDRANT_PORT=6333 \\"
echo "        -e QDRANT_GRPC_URL=http://qdrant:6334 \\"
echo "        -e QDRANT_GRPC_HOST=qdrant \\"
echo "        -e QDRANT_GRPC_PORT=6334 \\"
echo "        api python3 -m app.ingest --path \"$CONTAINER_PATH\" \$*"
echo

set -x
docker compose run --rm \
  -e QDRANT_URL="http://qdrant:6333" \
  -e QDRANT_HOST="qdrant" \
  -e QDRANT_PORT="6333" \
  -e QDRANT_GRPC_URL="http://qdrant:6334" \
  -e QDRANT_GRPC_HOST="qdrant" \
  -e QDRANT_GRPC_PORT="6334" \
  api \
  python3 -m app.ingest --path "$CONTAINER_PATH" "$@"
RET=$?
set +x

echo
echo "[i] docker compose run terminó con código: $RET"

exit $RET
