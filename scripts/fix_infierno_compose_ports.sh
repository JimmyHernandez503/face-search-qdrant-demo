#!/usr/bin/env bash
#
# fix_infierno_compose_ports.sh
#
# Reescribe docker-compose.yml para la demo "infierno" con:
#   - API FastAPI en http://localhost:9000
#   - Qdrant en puertos 9001 y 9002
#   - Nombres de contenedor: infierno-api, infierno-qdrant
#

set -euo pipefail

ROOT="$(pwd)"

echo "[1/3] Verificando que estamos en la raíz del proyecto..."
if [[ ! -f "${ROOT}/docker-compose.yml" ]]; then
  echo "[X] Aquí no hay docker-compose.yml. Coloca este script en la raíz del proyecto (donde está docker-compose.yml)."
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
echo "[2/3] Backup de docker-compose.yml -> docker-compose.yml.bak_${TS}"
cp docker-compose.yml "docker-compose.yml.bak_${TS}"

echo "[3/3] Escribiendo docker-compose.yml nuevo para la demo INFIERNO..."

cat > docker-compose.yml <<'EOF'
version: "3.8"

services:
  api:
    # Servicio FastAPI de la demo
    container_name: infierno-api
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    # API interna escucha en 7860, la exponemos en el host en 9000
    ports:
      - "9000:7860"
    # En el código normalmente se usa el host 'qdrant', así que dejamos
    # el servicio llamado 'qdrant' y solo cambiamos el container_name.
    environment:
      - QDRANT_HOST=qdrant
      - QDRANT_PORT=6333
    depends_on:
      - qdrant
    # Montajes típicos (ajusta si tu repo usa otros)
    volumes:
      - ./logs:/logs
      - ./state:/state
      - ./thumbs:/data/thumbs
      - ./models:/models
    # Usa GPU si está disponible
    gpus: all

  qdrant:
    # Motor de vectores Qdrant de la demo
    container_name: infierno-qdrant
    image: qdrant/qdrant:v1.9.1
    restart: unless-stopped
    # Qdrant escucha dentro del contenedor en 6333/6334,
    # lo exponemos en 9001 y 9002 para no pisar otra instancia.
    ports:
      - "9001:6333"
      - "9002:6334"
    volumes:
      - ./qdrant_storage:/qdrant/storage
EOF

echo
echo "OK. docker-compose.yml reescrito para la demo 'infierno'."
echo
echo "Puertos ahora:"
echo "  - API FastAPI demo : http://localhost:9000"
echo "  - Qdrant demo      : http://localhost:9001"
echo "  - Puerto extra Qdrant : 9002"
echo
echo "Recrea los contenedores con:"
echo "  docker compose down"
echo "  docker compose up -d --build"
