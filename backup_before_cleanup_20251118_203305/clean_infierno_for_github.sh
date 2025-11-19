#!/usr/bin/env bash
#
# clean_infierno_for_github.sh
#
# Deja la raíz del proyecto DEMO ("infierno") lista para GitHub:
#   - Hace backup de los .sh y docker-compose* / Dockerfile* actuales
#   - Borra todos los *.bak_* generados durante pruebas
#   - Mueve scripts "avanzados" a ./scripts/
#   - Deja en la raíz solo:
#       setup_infierno.sh
#       ingest_folder.sh
#       ingest_stats.sh
#       status.sh
#       backup_infierno.sh
#

set -euo pipefail

ROOT="$(pwd)"

echo "[1/5] Verificando que estamos en la raíz del proyecto..."
if [[ ! -f "${ROOT}/docker-compose.yml" ]] || [[ ! -f "${ROOT}/Dockerfile" ]]; then
  echo "  [X] Aquí no parece estar el docker-compose.yml y Dockerfile."
  echo "      Ejecuta este script desde la carpeta raíz de infierno_demo."
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
BACKDIR="${ROOT}/backup_before_cleanup_${TS}"

echo "[2/5] Creando backup de scripts y archivos clave en: ${BACKDIR}"
mkdir -p "${BACKDIR}"

# Backup de scripts .sh, docker-compose* y Dockerfile*
for f in *.sh docker-compose.yml docker-compose.override.yml Dockerfile*; do
  if [[ -e "$f" ]]; then
    cp -a "$f" "${BACKDIR}/"
  fi
done

echo "  [OK] Backup creado."

echo "[3/5] Borrando archivos *.bak_* de la raíz (restos de pruebas)..."
# Solo en la raíz, para no tocar nada dentro de app/
find "${ROOT}" -maxdepth 1 -type f -name '*.bak_*' -print -delete || true
echo "  [OK] Archivos .bak_* eliminados."

echo "[4/5] Moviendo scripts avanzados a ./scripts para limpiar la raíz..."

mkdir -p "${ROOT}/scripts"

move_if_exists() {
  local src="$1"
  if [[ -f "${ROOT}/${src}" ]]; then
    mv "${ROOT}/${src}" "${ROOT}/scripts/"
    echo "  [movido] ${src} -> scripts/"
  fi
}

# Scripts más avanzados / de mantenimiento que no son necesarios para el uso básico
move_if_exists "enable_host_mount_and_fix_ingest.sh"
move_if_exists "fix_gpu_qdrant.sh"
move_if_exists "fix_infierno_compose_ports.sh"
move_if_exists "make_infierno_demo.sh"
move_if_exists "monitor_infierno.sh"

# También movemos cualquier viejo monitor/backup/setup de oceano4 si aún queda alguno suelto
move_if_exists "monitor_oceano4.sh"
move_if_exists "setup_oceano4.sh"
move_if_exists "backup_oceano4.sh"

echo "  [OK] Scripts avanzados reubicados en ./scripts."

echo "[5/5] Resumen de lo que queda en la raíz (solo lo esencial + infra):"
echo
echo "  - Scripts principales:"
for f in setup_infierno.sh ingest_folder.sh ingest_stats.sh status.sh backup_infierno.sh; do
  [[ -f "$f" ]] && echo "      * $f"
done
echo
echo "  - Infraestructura:"
for f in docker-compose.yml docker-compose.override.yml Dockerfile app models logs qdrant_storage state thumbs; do
  [[ -e "$f" ]] && echo "      * $f"
done
echo
echo "  - Scripts avanzados ahora están en: ./scripts"
ls -1 scripts || true
echo
echo "Listo. Proyecto 'infierno_demo' más limpio para subir a GitHub."
echo "Si algo no te gusta, tienes todo el backup en: ${BACKDIR}"
