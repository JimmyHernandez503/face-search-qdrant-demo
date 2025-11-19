#!/usr/bin/env bash

# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ruta por defecto de la base de datos de ingesta (se puede sobrescribir con \$DB)
DB="${DB:-"$BASE/state/ingestion.db"}"

set -euo pipefail
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
