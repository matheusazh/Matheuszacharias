"""Letra: transcrição da voz isolada com Whisper (MLX), modelo baixado sob demanda."""

import logging
import os
import re
from pathlib import Path

import numpy as np

from . import audio, paths, protocol

log = logging.getLogger("splitter.lyrics")

WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"

# Frases que o Whisper "inventa" em trechos sem voz
_HALLUCINATIONS = re.compile(
    r"(legendas? (pela|por)|amara\.org|obrigad[oa] por assistir|inscreva-se|se inscreva|"
    r"deixe (seu|o seu) like|ative o sininho|transcri[çc][aã]o|subtitles? by|thanks for watching|♪)",
    re.IGNORECASE,
)


def _local_model_dir() -> Path | None:
    from huggingface_hub import snapshot_download
    try:
        return Path(snapshot_download(WHISPER_REPO, local_files_only=True))
    except Exception:
        return None


def status() -> dict:
    return {"whisper": _local_model_dir() is not None}


def download(progress_factory, params: dict) -> dict:
    """Baixa o Whisper medindo os bytes que chegam no cache (o progresso do hub é por arquivo, grosso demais)."""
    import threading
    from huggingface_hub import HfApi, snapshot_download

    progress = progress_factory([("download", "Baixando modelo de letra", 1)])
    with progress.step("download"):
        try:
            info = HfApi().model_info(WHISPER_REPO, files_metadata=True)
            total = sum((f.size or 0) for f in info.siblings) or 1
        except Exception:
            total = 1_600_000_000
        cache = Path(os.environ.get("HF_HOME", paths.MODELS_DIR / "hf"))
        before = _dir_size(cache)
        done = threading.Event()

        def watch():
            while not done.wait(0.5):
                progress.set_fraction(min(0.99, (_dir_size(cache) - before) / total))

        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
        try:
            path = snapshot_download(WHISPER_REPO)
        finally:
            done.set()
    return {"path": str(path)}


def _dir_size(root: Path) -> int:
    total = 0
    for dirpath, _, files in os.walk(root):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(dirpath, f))
            except OSError:
                pass
    return total


def transcribe(progress_factory, params: dict) -> dict:
    import mlx_whisper

    model_dir = _local_model_dir()
    if model_dir is None:
        raise RuntimeError("modelo de letra não instalado")
    progress = progress_factory([("load", "Preparando voz", 1), ("transcribe", "Transcrevendo a letra", 10)])
    with progress.step("load"):
        voice = audio.read(params["input"]).mean(axis=1)
        env = _voice_activity(voice)
        import soxr
        voice16 = soxr.resample(voice, audio.SAMPLE_RATE, 16000).astype(np.float32)
    with progress.step("transcribe"):
        duration = len(voice16) / 16000

        # o mlx_whisper usa tqdm com o total em quadros; a Bar repassa para o progresso
        import types
        import mlx_whisper.transcribe as tr
        tr.tqdm = types.SimpleNamespace(tqdm=protocol.Bar)
        result = mlx_whisper.transcribe(
            voice16,
            path_or_hf_repo=str(model_dir),
            language=params.get("language"),        # None = detecta (louvor em inglês também aparece)
            word_timestamps=True,
            condition_on_previous_text=False,
            no_speech_threshold=0.5,
            compression_ratio_threshold=2.2,
            hallucination_silence_threshold=2.0,
            verbose=None,
        )
    lines = []
    for seg in result.get("segments", []):
        text = seg.get("text", "").strip()
        if not text or _HALLUCINATIONS.search(text):
            continue
        if seg.get("no_speech_prob", 0) > 0.6 and seg.get("avg_logprob", 0) < -1.0:
            continue
        start, end = float(seg["start"]), float(seg["end"])
        if not _has_voice(env, start, end):
            continue
        words = [{"start": round(float(w["start"]), 3), "end": round(float(w["end"]), 3), "text": w["word"].strip()}
                 for w in seg.get("words", []) if w.get("word", "").strip()]
        lines.append({"start": round(start, 3), "end": round(min(end, duration), 3), "text": text, "words": words})
    return {"lines": lines, "language": result.get("language")}


def _voice_activity(mono: np.ndarray, hop: float = 0.1) -> np.ndarray:
    n = int(audio.SAMPLE_RATE * hop)
    frames = len(mono) // n
    if frames == 0:
        return np.zeros(0)
    rms = np.sqrt(np.mean(mono[: frames * n].reshape(frames, n) ** 2, axis=1))
    ref = np.percentile(rms, 95) or 1.0
    return rms > ref * 0.08


def _has_voice(env: np.ndarray, start: float, end: float, hop: float = 0.1) -> bool:
    a, z = int(start / hop), max(int(start / hop) + 1, int(end / hop))
    window = env[a:z]
    return bool(window.size) and float(window.mean()) > 0.15
