#!/usr/bin/env bash
#
# make_infierno_demo.sh
#
# Ajusta este repo limpio para usar:
#   - Nombre base: infierno
#   - Puertos base: 9000 (API), 9001/9002 (Qdrant)
#   - Renombra scripts *_infierno.sh -> *_infierno.sh
#

set -euo pipefail

ROOT="$(pwd)"

echo "[1/6] Verificando que estamos en la raíz del proyecto..."
if [[ ! -f "${ROOT}/docker-compose.yml" ]]; then
  echo "[X] Aquí no hay docker-compose.yml. Coloca este script en la raíz del proyecto (donde está docker-compose.yml)."
  exit 1
fi

echo "    Raíz del proyecto: ${ROOT}"

# ---------- 2) Backup de archivos clave ----------
TS="$(date +%Y%m%d_%H%M%S)"
echo "[2/6] Haciendo backups de docker-compose.yml y scripts *.sh..."

cp -n docker-compose.yml "docker-compose.yml.bak_${TS}" || true

for sh in *.sh; do
  [[ -f "$sh" ]] || continue
  cp -n "$sh" "${sh}.bak_${TS}" || true
done

# También Dockerfile por si acaso
if [[ -f Dockerfile ]]; then
  cp -n Dockerfile "Dockerfile.bak_${TS}" || true
fi

# ---------- 3) Ajustar docker-compose.yml ----------
echo "[3/6] Ajustando docker-compose.yml (nombres y puertos)..."

# Cambiar nombre de servicios/imagenes/container_name de infierno-* a infierno-*
sed -i -E '
s/infierno-api/infierno-api/g;
s/infierno-qdrant/infierno-qdrant/g;
' docker-compose.yml

# Ajustar mapeo de puertos del API:
# Host 9000 -> contenedor 7860 (dejamos el servicio interno en 7860 para no tocar el código Python)
sed -i -E '
s/"7860:7860"/"9000:7860"/g;
s/"9000:9000"/"9000:7860"/g;
s/"7860:9000"/"9000:7860"/g;
' docker-compose.yml

# Ajustar puertos de Qdrant:
# 6333 (gRPC/http interno) -> host 9001
# 6334 (otra exposición)   -> host 9002
sed -i -E '
s/"6333:6333"/"9001:6333"/g;
s/"6334:6334"/"9002:6334"/g;
' docker-compose.yml

echo "    - docker-compose.yml ajustado a infierno-api/infierno-qdrant y puertos 9000/9001/9002."

# ---------- 4) Renombrar scripts *_infierno.sh ----------
echo "[4/6] Renombrando scripts *_infierno.sh -> *_infierno.sh..."

declare -a RENAME_LIST=(
  "backup_infierno.sh"
  "monitor_infierno.sh"
  "setup_infierno.sh"
)

for old in "${RENAME_LIST[@]}"; do
  if [[ -f "$old" ]]; then
    new="$(echo "$old" | sed 's/infierno/infierno/g')"
    mv "$old" "$new"
    echo "    - $old -> $new"
  fi
done

# ---------- 5) Reemplazar 'infierno' -> 'infierno' dentro de scripts .sh ----------
echo "[5/6] Reemplazando referencias internas 'infierno' -> 'infierno' en scripts .sh..."

for sh in *.sh; do
  [[ -f "$sh" ]] || continue
  sed -i 's/infierno/infierno/g' "$sh"
done

# También hacer lo mismo en Dockerfile si había referencias
if [[ -f Dockerfile ]]; then
  sed -i 's/infierno/infierno/g' Dockerfile
fi

echo "    - Scripts y Dockerfile actualizados."

# ---------- 6) Mensaje final + ayuda ----------
echo "[6/6] Listo. Proyecto ajustado para DEMO 'infierno'."

cat <<EOF

Resumen de cambios:
  - Servicios y contenedores ahora se llaman:
      * infierno-api
      * infierno-qdrant
  - Puertos:
      * API web (FastAPI/uvicorn): http://localhost:9000  (mapea 9000 -> 7860 en el contenedor)
      * Qdrant:
          - gRPC/HTTP principal: 9001 (-> 6333 en contenedor)
          - Puerto extra:        9002 (-> 6334 en contenedor)
  - Scripts renombrados (si existían):
      * backup_infierno.sh
      * monitor_infierno.sh
      * setup_infierno.sh
  - Dentro de todos los .sh se reemplazó 'infierno' por 'infierno'.

Para levantar esta demo (infierno) sin pisar tu instancia original de infierno:

  1) Asegúrate de estar en este directorio:
        cd "${ROOT}"

  2) Ejecuta:
        docker compose up -d

  3) Accede al panel:
        http://localhost:9000/

Tu instancia original de infierno puede seguir usando 7860 y sus propios contenedores
(infierno-api / infierno-qdrant) sin conflicto.
EOF
