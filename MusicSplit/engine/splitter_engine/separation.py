"""Execução dos modelos de separação (audio-separator) com cache do modelo carregado."""

import logging
import os
import re
import shutil
import tempfile
from pathlib import Path

import numpy as np

from . import audio, paths

log = logging.getLogger("splitter.separation")

_separators: dict = {}      # nome do modelo -> Separator carregado
_MAX_LOADED = 2 if (os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")) >= 16 * 1024**3 else 1
# fp16 + torch.compile deixa os RoFormer ~5x mais rápidos na GPU do Mac, com o mesmo resultado.
# Se a compilação falhar numa máquina, cai para o modo normal e não tenta mais.
_accelerate = True


def _separator(model: str, workdir: str):
    from audio_separator.separator import Separator

    sep = _separators.pop(model, None)
    if sep is None:
        while len(_separators) >= _MAX_LOADED:
            old_name, old = next(iter(_separators.items()))
            del _separators[old_name]
            del old
            _empty_cache()
        sep = Separator(
            model_file_dir=str(paths.MODELS_DIR),
            output_dir=workdir,
            output_format="WAV",
            use_soundfile=True,
            log_level=logging.WARNING,
            normalization_threshold=1.0,
            use_native_fp16=_accelerate,
            use_torch_compile=_accelerate,
            demucs_params={"segment_size": "Default", "shifts": 1, "overlap": 0.25, "segments_enabled": True},
            # sobreposição 2 (em vez de 4 em alguns modelos): mesma qualidade medida, metade do tempo
            mdxc_params={"segment_size": 256, "override_model_segment_size": False, "batch_size": None,
                         "overlap": 2, "pitch_shift": 0},
        )
        sep.normalization_threshold = 1000.0  # sem normalizar: faixas somam de volta na mixagem
        sep.load_model(model_filename=model)
    _separators[model] = sep  # mais recente por último
    sep.output_dir = workdir
    if sep.model_instance is not None:
        sep.model_instance.output_dir = workdir
    return sep


def _empty_cache():
    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except Exception:
        pass


def run(model: str, source: np.ndarray, workdir: Path) -> dict[str, np.ndarray]:
    """Roda um modelo sobre `source` (amostras, 2) e devolve {nome_da_faixa_minúsculo: áudio}."""
    global _accelerate
    tmp = Path(tempfile.mkdtemp(prefix="sep-", dir=workdir))
    try:
        src = tmp / "input.wav"
        audio.write_float_wav(src, source)
        try:
            files = _separator(model, str(tmp)).separate(str(src))
        except Exception:
            if not _accelerate:
                raise
            log.exception("modo acelerado falhou; repetindo em fp32 sem compilação")
            _accelerate = False
            _separators.clear()
            _empty_cache()
            files = _separator(model, str(tmp)).separate(str(src))
        stems = {}
        for f in files:
            path = Path(f) if os.path.isabs(f) else tmp / f
            match = re.search(r"_\(([^)]+)\)_", path.name)
            name = (match.group(1) if match else path.stem).strip().lower()
            stems[name] = audio.match_length(audio.read(path), len(source))
        return stems
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pick(stems: dict[str, np.ndarray], *names: str) -> np.ndarray | None:
    for n in names:
        if n in stems:
            return stems[n]
    return None
