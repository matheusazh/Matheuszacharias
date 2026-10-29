"""Onde ficam os modelos.

SPLITTER_MODELS_DIR     pasta gravável (Application Support/MusicSplit/models)
SPLITTER_MODELS_BUNDLED pasta somente leitura dentro do .app (opcional)

Os arquivos embutidos ganham links simbólicos na pasta gravável; assim o audio-separator
enxerga tudo num lugar só e o que for baixado depois (ex.: Whisper) cai na pasta gravável.
"""

import os
from pathlib import Path

MODELS_DIR = Path(os.environ.get("SPLITTER_MODELS_DIR", Path.home() / "Library/Application Support/MusicSplit/models"))
BUNDLED_DIR = Path(os.environ["SPLITTER_MODELS_BUNDLED"]) if os.environ.get("SPLITTER_MODELS_BUNDLED") else None


def prepare():
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(MODELS_DIR / "hf"))
    os.environ.setdefault("TORCH_HOME", str(MODELS_DIR / "torch"))
    if not BUNDLED_DIR or not BUNDLED_DIR.is_dir():
        return
    for src in BUNDLED_DIR.iterdir():
        if src.name.startswith("."):
            continue
        dst = MODELS_DIR / src.name
        if dst.is_symlink():
            if os.readlink(dst) == str(src):
                continue
            dst.unlink()
        elif dst.exists():
            continue  # cópia real (baixada) tem prioridade
        dst.symlink_to(src)


def model_path(name: str) -> Path:
    return MODELS_DIR / name


def has_model(name: str) -> bool:
    return model_path(name).exists()
