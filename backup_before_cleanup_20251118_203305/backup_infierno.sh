#!/usr/bin/env bash
set -euo pipefail

BASE="/home/user2025/infierno"
BK_DIR="$BASE/backup"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$BK_DIR/infierno_backup_${TS}.tgz"

mkdir -p "$BK_DIR"

echo "== [1/8] Comprobaciones previas =="
command -v docker >/dev/null 2>&1 || { echo "Falta docker. Aborta."; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "Falta tar. Aborta."; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Falta sha256sum. Aborta."; exit 1; }
if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 no encontrado, no se generará inventario de ingesta."
fi

echo "== [2/8] Guardando metadatos de Docker Compose =="
# Copias de referencia + dump resolvido del compose
cp -f "$BASE/docker-compose.yml" "$BK_DIR/docker-compose.yml.$TS" 2>/dev/null || true
cp -f "$BASE/docker-compose.override.yml" "$BK_DIR/docker-compose.override.yml.$TS" 2>/dev/null || true
docker compose -f "$BASE/docker-compose.yml" -f "${BASE}/docker-compose.override.yml" config > "$BK_DIR/compose_config.$TS.yml" 2>/dev/null || docker compose -f "$BASE/docker-compose.yml" config > "$BK_DIR/compose_config.$TS.yml"
docker compose -f "$BASE/docker-compose.yml" images > "$BK_DIR/compose_images.$TS.txt" || true

echo "== [3/8] Deteniendo servicios (backup consistente) =="
pushd "$BASE" >/dev/null
docker compose down
popd >/dev/null

echo "== [4/8] Inventario (si hay SQLite) =="
if [ -f "$BASE/state/ingestion.db" ] && command -v sqlite3 >/dev/null 2>&1; then
  {
    echo "# Inventario infierno $TS"
    echo "Total archivos registrados:"
    sqlite3 "$BASE/state/ingestion.db" "SELECT COUNT(*) FROM files;"
    echo "Por estado (done/pending/error):"
    sqlite3 "$BASE/state/ingestion.db" "SELECT status, COUNT(*) FROM files GROUP BY status;"
  } > "$BK_DIR/inventory.$TS.txt"
else
  echo "No se encontró $BASE/state/ingestion.db o sqlite3; se omite inventario."
fi

echo "== [5/8] Preparando lista de contenidos a respaldar =="
# Directorios y archivos clave
TO_BACKUP=()
for p in \
  "$BASE/qdrant_storage" \
  "$BASE/state" \
  "$BASE/thumbs" \
  "$BASE/models" \
  "$BASE/app" \
  "$BASE/docker-compose.yml" \
  "$BASE/docker-compose.override.yml" \
  "$BASE/Dockerfile" \
  "$BASE/app/requirements.txt" \
  "$BASE"/*.sh
do
  [ -e "$p" ] && TO_BACKUP+=("$p")
done

echo "Elementos a respaldar:"
printf ' - %s\n' "${TO_BACKUP[@]}"

echo "== [6/8] Empaquetando en $OUT =="
tar -czf "$OUT" --absolute-names "${TO_BACKUP[@]}" "$BK_DIR/compose_config.$TS.yml" "$BK_DIR/compose_images.$TS.txt" "$BK_DIR/inventory.$TS.txt" 2>/dev/null || \
tar -czf "$OUT" --absolute-names "${TO_BACKUP[@]}" "$BK_DIR/compose_config.$TS.yml" "$BK_DIR/compose_images.$TS.txt"

echo "== [7/8] Checksums =="
pushd "$BK_DIR" >/dev/null
sha256sum "$(basename "$OUT")" > "checksums.$TS.sha256"
popd >/dev/null

echo "== [8/8] Listo =="
du -h "$OUT"
echo "SHA256:"
cat "$BK_DIR/checksums.$TS.sha256"
echo
echo "Archivo de respaldo:"
echo "  $OUT"
echo
echo "Para reanudar servicios aquí (opcional):"
echo "  cd $BASE && docker compose up -d"
