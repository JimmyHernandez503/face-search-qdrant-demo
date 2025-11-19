#!/usr/bin/env bash
set -euo pipefail
DB="/home/user2025/infierno/state/ingestion.db"
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
