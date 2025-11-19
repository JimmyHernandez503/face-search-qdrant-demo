#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Uso: $0 /ruta/a/la/carpeta (ej: /home/user2025/Descargas/04/00/00)"
  exit 1
fi

HOST_PATH="$1"

if [ ! -d "$HOST_PATH" ] && [ ! -f "$HOST_PATH" ]; then
  echo "No existe: $HOST_PATH"
  exit 1
fi

PREFIX="/home/user2025"
if [[ "$HOST_PATH" != $PREFIX* ]]; then
  echo "La ruta debe estar dentro de $PREFIX (montado como /hosthome en el contenedor)"
  exit 1
fi

CONT_PATH="/hosthome${HOST_PATH#$PREFIX}"

# Ejecuta la ingesta dentro del contenedor 'api' (ya tiene GPU por 'gpus: all' en compose)
cd /home/user2025/infierno
docker compose exec -T api python3 -m app.ingest --path "$CONT_PATH" --batch 256
