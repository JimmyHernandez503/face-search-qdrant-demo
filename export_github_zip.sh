#!/usr/bin/env bash
set -euo pipefail

# Carpeta base = donde está este script
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE"

PROJECT_NAME="$(basename "$BASE")"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="${PROJECT_NAME}_github_${TS}.zip"

echo "[i] Exportando código desde: $BASE"
echo "[i] Archivo de salida: $OUT"
echo

# Lista de carpetas a excluir del ZIP (datos pesados / locales)
EXCLUDES=(
  "qdrant_storage"
  "logs"
  "state"
  "thumbs"
  "models"
  "__pycache__"
  ".git"
  ".venv"
)

# Construir argumentos -x para zip
EX_ARGS=()
for e in "${EXCLUDES[@]}"; do
  EX_ARGS+=( "-x" "${e}/*" )
done

# Evitar incluir otros backups/zip/tar dentro del ZIP nuevo
EX_ARGS+=( "-x" "*.zip" "*.tar" "*.tgz" "*.tar.gz" )

echo "[i] Ejecutando zip..."
echo "    zip -r \"$OUT\" . ${EX_ARGS[*]}"
echo

zip -r "$OUT" . "${EX_ARGS[@]}"

echo
echo "[✓] ZIP generado correctamente:"
echo "    $BASE/$OUT"
echo
echo "[i] Contiene solo código/config, sin datos de Qdrant, logs ni modelos."
