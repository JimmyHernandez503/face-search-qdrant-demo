#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

echo "[i] Base del proyecto: $BASE_DIR"

#############################################
# 1) docker-compose.yml  -> ${HOME}:/hosthome
#############################################
if [[ -f "docker-compose.yml" ]]; then
  echo "[1/5] Parchando docker-compose.yml ..."
  python3 << 'PY'
import pathlib, datetime

path = pathlib.Path("docker-compose.yml")
txt = path.read_text(encoding="utf-8")

if "/home/user2025" not in txt:
    print("  [i] No se encontró '/home/user2025' en docker-compose.yml (nada que cambiar).")
else:
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup = path.with_suffix(path.suffix + f".bak_portable_{ts}")
    backup.write_text(txt, encoding="utf-8")
    new = txt.replace("/home/user2025:/hosthome", "${HOME}:/hosthome")
    path.write_text(new, encoding="utf-8")
    print(f"  [OK] Backup: {backup}")
PY
else
  echo "[1/5] docker-compose.yml no encontrado, salto."
fi

#############################################
# 2) backup_infierno.sh -> BASE dinámico
#############################################
if [[ -f "backup_infierno.sh" ]]; then
  echo "[2/5] Parchando backup_infierno.sh ..."
  python3 << 'PY'
import pathlib, datetime
from pathlib import Path

path = Path("backup_infierno.sh")
txt = path.read_text(encoding="utf-8")
ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = path.with_suffix(path.suffix + f".bak_portable_{ts}")
backup.write_text(txt, encoding="utf-8")

lines = txt.splitlines(keepends=True)

snippet = '''# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
'''

out = []
inserted = False

for line in lines:
    if (not inserted and
        line.lstrip().startswith("BASE=") and
        "/home/" in line):
        out.append(snippet)
        inserted = True
        continue
    out.append(line)

if not inserted:
    # Si no había BASE duro, lo metemos cerca del principio
    out2 = []
    injected = False
    for line in out:
        if not injected and line.startswith("#!"):
            out2.append(line)
            out2.append("\n" + snippet)
            injected = True
            continue
        out2.append(line)
    if not injected:
        out2 = [snippet, "\n"] + out
    out = out2

path.write_text("".join(out), encoding="utf-8")
print(f"  [OK] Backup: {backup}")
PY
else
  echo "[2/5] backup_infierno.sh no encontrado, salto."
fi

#############################################
# 3) ingest_stats.sh -> BASE + DB relativo
#############################################
if [[ -f "ingest_stats.sh" ]]; then
  echo "[3/5] Parchando ingest_stats.sh ..."
  python3 << 'PY'
import pathlib, datetime
from pathlib import Path

path = Path("ingest_stats.sh")
txt = path.read_text(encoding="utf-8")
ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = path.with_suffix(path.suffix + f".bak_portable_{ts}")
backup.write_text(txt, encoding="utf-8")

lines = txt.splitlines(keepends=True)

snippet = '''# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Ruta por defecto de la base de datos de ingesta (se puede sobrescribir con \$DB)
DB="${DB:-"$BASE/state/ingestion.db"}"

'''

out = []
inserted = False

for i, line in enumerate(lines):
    # Insertar snippet justo después del shebang
    if not inserted and line.startswith("#!"):
        out.append(line)
        out.append("\n" + snippet)
        inserted = True
        continue
    # Eliminar definiciones viejas de DB con rutas absolutas
    if "DB=" in line and "/home/" in line:
        continue
    out.append(line)

if not inserted:
    out = [snippet] + out

path.write_text("".join(out), encoding="utf-8")
print(f"  [OK] Backup: {backup}")
PY
else
  echo "[3/5] ingest_stats.sh no encontrado, salto."
fi

#############################################
# 4) ingest_folder.sh -> BASE + HOST_HOME=$HOME
#############################################
if [[ -f "ingest_folder.sh" ]]; then
  echo "[4/5] Parchando ingest_folder.sh ..."
  python3 << 'PY'
import pathlib, datetime
from pathlib import Path

path = Path("ingest_folder.sh")
txt = path.read_text(encoding="utf-8")
ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = path.with_suffix(path.suffix + f".bak_portable_{ts}")
backup.write_text(txt, encoding="utf-8")

snippet = '''# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directorio HOME del host (por defecto, \$HOME del usuario actual)
HOST_HOME="${HOST_HOME:-$HOME}"

'''

lines = txt.splitlines(keepends=True)
out = []
inserted = False

for i, line in enumerate(lines):
    if not inserted and line.startswith("#!"):
        out.append(line)
        out.append("\n" + snippet)
        inserted = True
        continue
    # Eliminar definiciones viejas de HOST_HOME y BASE con /home/...
    if "HOST_HOME=" in line and "/home/" in line:
        continue
    if line.lstrip().startswith("BASE=") and "/home/" in line:
        continue
    out.append(line)

if not inserted:
    out = [snippet] + out

path.write_text("".join(out), encoding="utf-8")
print(f"  [OK] Backup: {backup}")
PY
else
  echo "[4/5] ingest_folder.sh no encontrado, salto."
fi

#############################################
# 5) setup_infierno.sh -> BASE dinámico
#############################################
if [[ -f "setup_infierno.sh" ]]; then
  echo "[5/5] Parchando setup_infierno.sh ..."
  python3 << 'PY'
import pathlib, datetime
from pathlib import Path

path = Path("setup_infierno.sh")
txt = path.read_text(encoding="utf-8")
ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = path.with_suffix(path.suffix + f".bak_portable_{ts}")
backup.write_text(txt, encoding="utf-8")

lines = txt.splitlines(keepends=True)

snippet = '''# Directorio base del proyecto (carpeta donde está este script)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
'''

out = []
inserted = False

for line in lines:
    if (not inserted and
        line.lstrip().startswith("BASE=") and
        "/home/" in line):
        out.append(snippet)
        inserted = True
        continue
    out.append(line)

if not inserted:
    tmp = []
    inj = False
    for l in out:
        if not inj and l.startswith("#!"):
            tmp.append(l)
            tmp.append("\n" + snippet)
            inj = True
            continue
        tmp.append(l)
    if not inj:
        tmp = [snippet, "\n"] + out
    out = tmp

path.write_text("".join(out), encoding="utf-8")
print(f"  [OK] Backup: {backup}")
PY
else
  echo "[5/5] setup_infierno.sh no encontrado, salto."
fi

echo
echo "[✓] Parche de portabilidad aplicado."
echo "    Ahora puedes clonar el repo en cualquier ruta y usar:"
echo "      docker compose up -d --build"
echo "      bash ingest_folder.sh \"\$HOME/Documentos/lo_que_sea\""
