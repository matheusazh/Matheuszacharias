#!/bin/zsh
# Monta o Python embutido do motor em vendor/python (python-build-standalone relocável + dependências).
# Uso: scripts/build-engine.sh
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

PY=3.12
OUT=vendor/python
TMP=vendor/.python-build
rm -rf "$OUT" "$TMP"
mkdir -p "$TMP"

echo "→ Python $PY (python-build-standalone)"
uv python install "$PY" --install-dir "$TMP" --no-bin >/dev/null
SRC=$(find "$TMP" -maxdepth 1 -type d -name "cpython-${PY}.*-macos-aarch64-none" | head -1)
ditto "$SRC" "$OUT"
rm -rf "$TMP"
PYBIN="$OUT/bin/python3"

echo "→ dependências (travadas pelo uv.lock)"
(cd engine && uv export --frozen --no-dev --no-hashes --no-emit-project --format requirements-txt) > vendor/requirements.txt
uv pip install --python "$PYBIN" --break-system-packages --quiet -r vendor/requirements.txt

echo "→ enxugando"
LIB="$OUT/lib/python$PY"
SP="$LIB/site-packages"
rm -rf "$LIB"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} "$LIB"/config-$PY-darwin
rm -rf "$OUT"/lib/{tcl*,tk*,itcl*,thread*} "$OUT"/share "$OUT"/include
# torch/include sai, menos c10/metal: o torch.compile no Mac compila shaders Metal com esses headers
find "$SP"/torch/include -mindepth 1 -maxdepth 1 ! -name c10 -exec rm -rf {} +
find "$SP"/torch/include/c10 -mindepth 1 -maxdepth 1 ! -name metal -exec rm -rf {} +
rm -rf "$SP"/torch/share/cmake
rm -rf "$SP"/pip "$SP"/pip-* "$SP"/setuptools/_vendor/*/tests
find "$OUT" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$OUT" -name "*.a" -delete   # .pyi fica: o librosa carrega os stubs em tempo de execução
find "$SP" -type d \( -name "tests" -o -name "test" \) -path "*/site-packages/*/*" -prune \
  ! -path "*/torch/*" ! -path "*/numpy/*" -exec rm -rf {} + 2>/dev/null || true

echo "→ pré-compilando .pyc"
"$PYBIN" -m compileall -q -j0 "$LIB" >/dev/null 2>&1 || true

echo "→ teste"
"$PYBIN" -c "
import torch, audio_separator.separator, beat_this.inference, lv_chordia, mlx_whisper, librosa, pyloudnorm
print('ok: torch', torch.__version__, '| mps', torch.backends.mps.is_available())
import os; os._exit(0)   # evita a trava de finalização do torch/mlx
"
du -sh "$OUT"
