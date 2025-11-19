#!/usr/bin/env bash
set -euo pipefail

BASE="/home/user2025/infierno"
OVR="$BASE/docker-compose.override.yml"
SCRIPT="$BASE/ingest_folder.sh"
PREFIX="/home/user2025"

echo "[1/3] Creando override para montar $PREFIX dentro del contenedor en /hosthome (ro)..."
mkdir -p "$BASE"
cat > "$OVR" <<'YAML'
services:
  api:
    volumes:
      - /home/user2025:/hosthome:ro
YAML
echo "  -> Escribí: $OVR"

echo "[2/3] Reemplazando ingest_folder.sh para ejecutar dentro del contenedor (sin --gpus)..."
# Backup si existía
if [ -f "$SCRIPT" ]; then
  cp -f "$SCRIPT" "$SCRIPT.bak.$(date +%s)"
  echo "  -> Backup: $SCRIPT.bak.*"
fi

cat > "$SCRIPT" <<'SH'
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
SH
chmod +x "$SCRIPT"
echo "  -> Escribí + hice ejecutable: $SCRIPT"

echo "[3/3] Aplicando override y (re)lanzando servicios..."
cd "$BASE"
docker compose up -d

echo
echo "=========================================================="
echo " Listo."
echo
echo " Ahora puedes ingestar una carpeta del host (debe estar bajo $PREFIX):"
echo "   $SCRIPT \"$PREFIX/Descargas/04/00/00\""
echo
echo " Ver progreso:"
echo "   $BASE/ingest_stats.sh"
echo
echo " Estado y logs:"
echo "   $BASE/status.sh"
echo
echo " Nota:"
echo " - Montamos $PREFIX dentro del contenedor como /hosthome:ro."
echo " - El flag '--gpus' ya no es necesario porque el servicio 'api' se arrancó con 'gpus: all'."
echo " - Si necesitas ingestar otra ruta fuera de $PREFIX, añade otro volumen en $OVR y vuelve a 'docker compose up -d'."
echo "=========================================================="
