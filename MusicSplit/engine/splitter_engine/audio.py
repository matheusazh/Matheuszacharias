"""Leitura e gravação de áudio do projeto (44,1 kHz, estéreo)."""

import numpy as np
import soundfile as sf

SAMPLE_RATE = 44100


def read(path) -> np.ndarray:
    """Retorna (amostras, 2) float32 em 44,1 kHz."""
    audio, sr = sf.read(str(path), dtype="float32", always_2d=True)
    if sr != SAMPLE_RATE:
        import soxr
        audio = soxr.resample(audio, sr, SAMPLE_RATE).astype(np.float32)
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    elif audio.shape[1] > 2:
        audio = audio[:, :2]
    return audio


def write_float_wav(path, audio: np.ndarray):
    sf.write(str(path), audio, SAMPLE_RATE, subtype="FLOAT", format="WAV")


def write_stem(path, audio: np.ndarray) -> float:
    """Grava FLAC 24 bits. Se passar de 0 dBFS, grava reduzido e devolve o ganho
    que o app deve reaplicar na reprodução (assim a soma das faixas volta à mixagem)."""
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    gain = 1.0
    if peak > 0.999:
        gain = peak / 0.999
        audio = audio / gain
    sf.write(str(path), audio, SAMPLE_RATE, subtype="PCM_24", format="FLAC")
    return gain


def match_length(audio: np.ndarray, frames: int) -> np.ndarray:
    if len(audio) == frames:
        return audio
    if len(audio) > frames:
        return audio[:frames]
    return np.pad(audio, ((0, frames - len(audio)), (0, 0)))


def loudness(audio: np.ndarray) -> float | None:
    """Loudness integrado (LUFS, BS.1770). None para silêncio."""
    import pyloudnorm
    if audio.size == 0 or np.max(np.abs(audio)) < 1e-5:
        return None
    meter = pyloudnorm.Meter(SAMPLE_RATE)
    value = meter.integrated_loudness(audio.astype(np.float64))
    return None if not np.isfinite(value) else round(float(value), 2)
