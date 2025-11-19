#!/usr/bin/env bash
# Monitor simple de infierno: CPU, RAM, NET por contenedor + GPU (si hay)
# Requisitos: docker, curl. Opcional: nvidia-smi, jq
set -euo pipefail

API_CONT="infierno-api"
QDR_CONT="infierno-qdrant"
API_PORT=7860
REFRESH="${1:-2}"   # intervalo en segundos (opcional, por defecto 2s)

# Helper: lee contador de bytes (RX/TX) de eth0 dentro del contenedor
get_bytes() {
  local cont="$1" dir="$2" # dir=rx|tx
  docker exec "$cont" bash -lc "cat /sys/class/net/eth0/statistics/${dir}_bytes" 2>/dev/null || echo 0
}

# Inicializar contadores de red
prev_rx_api=$(get_bytes "$API_CONT" rx)
prev_tx_api=$(get_bytes "$API_CONT" tx)
prev_rx_qdr=$(get_bytes "$QDR_CONT" rx)
prev_tx_qdr=$(get_bytes "$QDR_CONT" tx)
prev_ts=$(date +%s)

# Detección de nvidia-smi
HAS_NVIDIA=1
if ! command -v nvidia-smi >/dev/null 2>&1; then
  HAS_NVIDIA=0
fi

while :; do
  clear
  now_ts=$(date +%s)
  dt=$(( now_ts - prev_ts ))
  (( dt == 0 )) && dt=1

  # --- Encabezado ---
  echo "infierno Monitor  |  $(date)  |  refresh: ${REFRESH}s"
  echo "API: http://localhost:${API_PORT}    (Ctrl+C para salir)"
  echo

  # --- docker stats (CPU, MEM, NET acumulado, PIDs) ---
  echo "== Docker stats (CPU, MEM, NET, PIDs) =="
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}" \
    | (read -r; printf "%s\n" "$REPLY"; grep -E "$API_CONT|$QDR_CONT" || true)
  echo

  # --- Estado colección (vectores) ---
  echo "== Estado API (/status) =="
  STATUS_JSON=$(curl -s "http://127.0.0.1:${API_PORT}/status" || echo "{}")
  if command -v jq >/dev/null 2>&1; then
    echo "$STATUS_JSON" | jq .
  else
    echo "$STATUS_JSON"
  fi
  echo

  # --- GPU (si disponible) ---
  if [[ "$HAS_NVIDIA" -eq 1 ]]; then
    echo "== GPU resumen (nvidia-smi) =="
    nvidia-smi --query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu \
               --format=csv,noheader,nounits 2>/dev/null || echo "nvidia-smi no disponible"
    echo
    echo "== GPU procesos (PID, proceso, VRAM usada) =="
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null \
      | sed 's/^/  /' || true
    echo
  else
    echo "== GPU =="
    echo "nvidia-smi no encontrado en el host; mostrando solo métricas de CPU/RAM/NET."
    echo
  fi

  # --- Red por contenedor (tasa instantánea) ---
  rx_api=$(get_bytes "$API_CONT" rx)
  tx_api=$(get_bytes "$API_CONT" tx)
  rx_qdr=$(get_bytes "$QDR_CONT" rx)
  tx_qdr=$(get_bytes "$QDR_CONT" tx)

  d_rx_api=$(( rx_api - prev_rx_api ))
  d_tx_api=$(( tx_api - prev_tx_api ))
  d_rx_qdr=$(( rx_qdr - prev_rx_qdr ))
  d_tx_qdr=$(( tx_qdr - prev_tx_qdr ))

  # Bytes/s -> MBytes/s con 2 decimales
  rate_api_rx=$(awk -v b=$d_rx_api -v t=$dt 'BEGIN{printf "%.2f", b/(1024*1024)/t}')
  rate_api_tx=$(awk -v b=$d_tx_api -v t=$dt 'BEGIN{printf "%.2f", b/(1024*1024)/t}')
  rate_qdr_rx=$(awk -v b=$d_rx_qdr -v t=$dt 'BEGIN{printf "%.2f", b/(1024*1024)/t}')
  rate_qdr_tx=$(awk -v b=$d_tx_qdr -v t=$dt 'BEGIN{printf "%.2f", b/(1024*1024)/t}')

  echo "== Red (MB/s) =="
  printf "  %-15s  RX: %6s  TX: %6s\n" "$API_CONT" "$rate_api_rx" "$rate_api_tx"
  printf "  %-15s  RX: %6s  TX: %6s\n" "$QDR_CONT" "$rate_qdr_rx" "$rate_qdr_tx"
  echo

  # Actualizar previos
  prev_rx_api=$rx_api; prev_tx_api=$tx_api
  prev_rx_qdr=$rx_qdr; prev_tx_qdr=$tx_qdr
  prev_ts=$now_ts

  sleep "$REFRESH"
done
