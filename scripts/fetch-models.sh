#!/bin/zsh
# Baixa os modelos escolhidos (engine/splitter_engine/pipelines.py → MODELS) para vendor/models.
# Os RoFormer (.ckpt) são gravados em float16: metade do tamanho e o mesmo resultado,
# porque o motor já roda em fp16 na GPU. Uso: scripts/fetch-models.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE=vendor/.models-cache
OUT=vendor/models
mkdir -p "$CACHE" "$OUT"

engine/.venv/bin/python - "$CACHE" "$OUT" <<'PY'
import logging, shutil, sys, urllib.request
from pathlib import Path
import torch

sys.path.insert(0, "engine")
from splitter_engine.pipelines import MODELS
from splitter_engine.analysis import BEAT_CKPT
from audio_separator.separator import Separator

cache, out = Path(sys.argv[1]), Path(sys.argv[2])

# 1. o próprio audio-separator baixa cada modelo + configs (e os JSON de parâmetros dos modelos VR)
sep = Separator(model_file_dir=str(cache), output_dir=str(cache), log_level=logging.WARNING)
for key, name in MODELS.items():
    print(f"↓ {key}: {name}", flush=True)
    sep.load_model(model_filename=name)
    sep.model_instance = None

# 2. Beat This! (batidas e compassos)
beat = cache / BEAT_CKPT
if not beat.exists():
    print("↓ beat this", flush=True)
    urllib.request.urlretrieve("https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt", beat)

# 3. copia para vendor/models, convertendo os .ckpt para float16
def half(obj):
    if isinstance(obj, torch.Tensor):
        return obj.half() if obj.is_floating_point() else obj
    if isinstance(obj, dict):
        return {k: half(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return type(obj)(half(v) for v in obj)
    return obj

for f in sorted(cache.iterdir()):
    if f.name.startswith(".") or f.is_dir():
        continue
    dst = out / f.name
    if dst.exists() and dst.stat().st_mtime >= f.stat().st_mtime:
        continue
    if f.suffix == ".ckpt":
        state = torch.load(f, map_location="cpu", weights_only=False)
        torch.save(half(state), dst)
        print(f"  fp16 {f.name}: {f.stat().st_size / 1e6:.0f} → {dst.stat().st_size / 1e6:.0f} MB", flush=True)
    else:
        shutil.copy2(f, dst)
PY
du -sh "$OUT"
ls -la "$OUT"
