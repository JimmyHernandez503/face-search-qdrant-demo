#!/usr/bin/env bash
set -euo pipefail
echo "=== docker compose ps ==="
docker compose ps
echo
echo "=== API /status ==="
STATUS=$(curl -s http://localhost:9002/status || true)
if command -v jq >/dev/null 2>&1; then
  echo "$STATUS" | jq .
else
  echo "$STATUS"
fi
echo
echo "=== Últimas 50 líneas de logs (api) ==="
docker compose logs --tail 50 api || true
