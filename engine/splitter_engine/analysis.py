"""Análise musical: batidas/compasso, BPM, acordes, tonalidade e partes da música."""

import logging
from pathlib import Path

import numpy as np

from . import audio, paths

log = logging.getLogger("splitter.analysis")

BEAT_CKPT = "beat_this-final0.ckpt"
NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
PITCH = {"C": 0, "B#": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "Fb": 4, "E#": 5, "F": 5,
         "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11, "Cb": 11}


# ---------------------------------------------------------------- batidas

def beats(mix_path: Path) -> dict:
    from beat_this.inference import File2Beats

    ckpt = paths.model_path(BEAT_CKPT)
    f2b = File2Beats(checkpoint_path=str(ckpt) if ckpt.exists() else "final0", device="cpu", dbn=False)
    beat_times, downbeat_times = f2b(str(mix_path))
    beat_times = [round(float(t), 3) for t in beat_times]
    downbeat_times = [round(float(t), 3) for t in downbeat_times]
    bpm = None
    if len(beat_times) > 4:
        bpm = round(float(60.0 / np.median(np.diff(beat_times))), 1)
    meter = 4
    if len(downbeat_times) > 2:
        counts = []
        b = np.array(beat_times)
        for a, z in zip(downbeat_times[:-1], downbeat_times[1:]):
            counts.append(int(np.sum((b >= a - 0.02) & (b < z - 0.02))))
        if counts:
            meter = int(np.bincount(counts).argmax()) or 4
    return {"beats": beat_times, "downbeats": downbeat_times, "bpm": bpm, "meter": meter}


# ---------------------------------------------------------------- acordes

def chords(harmonic_path: Path, beat_times: list[float]) -> list[dict]:
    from lv_chordia import chord_recognition

    raw = chord_recognition(str(harmonic_path), chord_dict_name="submission")
    segs = [{"start": r["start_time"], "end": r["end_time"], "label": r["chord"]} for r in raw]
    segs = [s for s in segs if s["end"] - s["start"] > 0.05]
    # silêncios curtos ("N") entre acordes e acordes curtíssimos viram parte do vizinho
    merged: list[dict] = []
    for s in segs:
        dur = s["end"] - s["start"]
        short_gap = s["label"] in ("N", "X") and dur < 1.5
        if merged and (s["label"] == merged[-1]["label"] or short_gap or dur < 0.35):
            merged[-1]["end"] = s["end"]
        elif merged and merged[-1]["label"] in ("N", "X") and merged[-1]["end"] - merged[-1]["start"] < 1.5:
            merged[-1] = {"start": merged[-1]["start"], "end": s["end"], "label": s["label"]}
        else:
            merged.append(dict(s))
    # depois de absorver os silêncios, junta acordes iguais que ficaram lado a lado
    compact: list[dict] = []
    for s in merged:
        if compact and compact[-1]["label"] == s["label"]:
            compact[-1]["end"] = s["end"]
        else:
            compact.append(s)
    merged = compact
    # encosta as trocas na batida mais próxima (até 150 ms) para a linha ficar limpa
    if beat_times:
        b = np.array(beat_times)
        for s in merged[1:]:
            i = int(np.argmin(np.abs(b - s["start"])))
            if abs(b[i] - s["start"]) < 0.15:
                s["start"] = round(float(b[i]), 3)
        for a, z in zip(merged[:-1], merged[1:]):
            a["end"] = z["start"]
    return [{"start": round(s["start"], 3), "end": round(s["end"], 3), "label": s["label"]} for s in merged]


def _parse(label: str):
    """'A:min7/b3' -> (9, 'min'). None para 'N'/'X'."""
    if label in ("N", "X") or ":" not in label and label not in PITCH:
        return None
    root, _, quality = label.partition(":")
    quality = quality.split("/")[0] or "maj"
    if root not in PITCH:
        return None
    base = "min" if quality.startswith("min") or quality.startswith("dim") or quality.startswith("hdim") else "maj"
    return PITCH[root], base


# ---------------------------------------------------------------- tonalidade

_MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
_MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def key(harmonic: np.ndarray, chord_segs: list[dict]) -> dict | None:
    import librosa

    mono = harmonic.mean(axis=1)
    if np.max(np.abs(mono)) < 1e-4:
        return None
    y = librosa.resample(mono, orig_sr=audio.SAMPLE_RATE, target_sr=22050)
    chroma = librosa.feature.chroma_cqt(y=y, sr=22050).mean(axis=1)
    scores = np.zeros(24)
    for k in range(12):
        scores[k] = np.corrcoef(np.roll(_MAJOR_PROFILE, k), chroma)[0, 1]
        scores[12 + k] = np.corrcoef(np.roll(_MINOR_PROFILE, k), chroma)[0, 1]
    # voto dos acordes: diatônicos somam, tônica soma mais, começo e fim pesam mais
    votes = np.zeros(24)
    total = sum(s["end"] - s["start"] for s in chord_segs) or 1.0
    major_diatonic = {0: "maj", 2: "min", 4: "min", 5: "maj", 7: "maj", 9: "min"}
    minor_diatonic = {0: "min", 3: "maj", 5: "min", 7: "min", 8: "maj", 10: "maj"}
    parsed = [(p, s["end"] - s["start"]) for s in chord_segs if (p := _parse(s["label"]))]
    for idx, ((root, quality), dur) in enumerate(parsed):
        w = dur / total
        if idx < 2 or idx >= len(parsed) - 2:
            w *= 1.5
        for k in range(12):
            deg = (root - k) % 12
            if major_diatonic.get(deg) == quality:
                votes[k] += w * (2.0 if deg == 0 else 1.0)
            if minor_diatonic.get(deg) == quality or (deg == 7 and quality == "maj"):
                votes[12 + k] += w * (2.0 if deg == 0 else 1.0)
    if votes.max() > 0:
        votes = votes / votes.max()
    combined = 0.5 * (scores - scores.min()) / (np.ptp(scores) or 1) + 0.5 * votes
    best = int(np.argmax(combined))
    tonic = best % 12
    mode = "major" if best < 12 else "minor"
    return {"tonic": NOTE_NAMES[tonic], "mode": mode, "pitchClass": tonic,
            "confidence": round(float(combined[best] - np.partition(combined, -2)[-2]), 3)}


# ---------------------------------------------------------------- partes da música

def sections(mix: np.ndarray, vocals: np.ndarray | None, beat_times: list[float], downbeat_times: list[float]) -> list[dict]:
    """Partes da música no nível do compasso: matriz de auto-similaridade (cromagrama + timbre),
    novidade com kernel xadrez (Foote) para as fronteiras, agrupamento das partes parecidas
    e nomes por heurística (repetição, energia e presença de voz)."""
    import librosa
    import scipy.signal
    from sklearn.cluster import AgglomerativeClustering

    duration = len(mix) / audio.SAMPLE_RATE
    beat_len = float(np.median(np.diff(beat_times))) if len(beat_times) > 2 else 0.5
    bars = [t for t in downbeat_times if t < duration - 1]
    if len(bars) < 12 or duration < 40:
        return [{"start": 0.0, "end": round(duration, 3), "label": "Música"}]

    sr, hop = 22050, 512
    y = librosa.resample(mix.mean(axis=1), orig_sr=audio.SAMPLE_RATE, target_sr=sr)
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop)
    mfcc = librosa.feature.mfcc(y=y, sr=sr, hop_length=hop, n_mfcc=14)[1:]
    frames = librosa.time_to_frames(np.array(bars), sr=sr, hop_length=hop)
    # uma coluna por compasso (descarta o trecho antes do 1º tempo forte)
    cb = librosa.util.sync(chroma, frames, aggregate=np.median)[:, 1:]
    mb = librosa.util.sync(mfcc, frames, aggregate=np.mean)[:, 1:]
    n = cb.shape[1]

    def zs(m):
        return (m - m.mean(axis=1, keepdims=True)) / (m.std(axis=1, keepdims=True) + 1e-6)

    feats = np.vstack([zs(cb), 0.8 * zs(mb)])
    unit = feats / (np.linalg.norm(feats, axis=0, keepdims=True) + 1e-9)
    ssm = unit.T @ unit

    # novidade de Foote: kernel xadrez gaussiano de 4 compassos para cada lado
    half = 4
    g = np.exp(-0.5 * (np.linspace(-1.5, 1.5, 2 * half)) ** 2)
    kernel = np.outer(g, g) * np.sign(np.outer(np.r_[-np.ones(half), np.ones(half)], np.r_[-np.ones(half), np.ones(half)]))
    padded = np.pad(ssm, half, mode="edge")
    novelty = np.array([np.sum(padded[i:i + 2 * half, i:i + 2 * half] * kernel) for i in range(n)])
    novelty = np.maximum(0, novelty - np.median(novelty))
    peaks, _ = scipy.signal.find_peaks(novelty, distance=4, prominence=0.5 * float(np.std(novelty) or 1))
    bounds = [0] + [int(p) for p in peaks if 3 <= p <= n - 3] + [n]

    # partes com menos de 4 compassos se juntam à vizinha mais parecida
    def seg_mean(a, z):
        return unit[:, a:z].mean(axis=1)

    changed = True
    while changed and len(bounds) > 2:
        changed = False
        for i in range(len(bounds) - 1):
            a, z = bounds[i], bounds[i + 1]
            if z - a >= 4:
                continue
            here = seg_mean(a, z)
            left = seg_mean(bounds[i - 1], a) if i > 0 else None
            right = seg_mean(z, bounds[i + 2]) if i + 2 < len(bounds) else None
            sim_l = float(here @ left) if left is not None else -9
            sim_r = float(here @ right) if right is not None else -9
            del bounds[i if sim_l >= sim_r else i + 1]
            changed = True
            break

    segs = list(zip(bounds[:-1], bounds[1:]))
    means = np.array([seg_mean(a, z) for a, z in segs])
    if len(segs) >= 3:
        clustering = AgglomerativeClustering(n_clusters=None, distance_threshold=0.55, metric="cosine", linkage="average")
        clusters = clustering.fit_predict(means)
    else:
        clusters = np.arange(len(segs))

    def bar_time(i):
        return 0.0 if i == 0 else (bars[i] if i < len(bars) else duration)

    out = [{"start": bar_time(a), "end": bar_time(z), "cluster": int(c)} for (a, z), c in zip(segs, clusters)]
    out[-1]["end"] = duration
    # vizinhas do mesmo grupo viram uma parte só
    merged = [out[0]]
    for s in out[1:]:
        if s["cluster"] == merged[-1]["cluster"]:
            merged[-1]["end"] = s["end"]
        else:
            merged.append(s)
    log.info("partes: %d compassos, %d fronteiras, %d partes, %d grupos", n, len(bounds) - 2, len(merged), len(set(clusters)))
    return _name_sections(merged, mix, vocals, duration)


def _rms(x: np.ndarray, a: float, z: float) -> float:
    seg = x[int(a * audio.SAMPLE_RATE):int(z * audio.SAMPLE_RATE)]
    return float(np.sqrt(np.mean(seg ** 2))) if seg.size else 0.0


def _name_sections(segs: list[dict], mix: np.ndarray, vocals: np.ndarray | None, duration: float) -> list[dict]:
    mix_rms = np.array([_rms(mix, s["start"], s["end"]) for s in segs])
    voc_rms = np.array([_rms(vocals, s["start"], s["end"]) for s in segs]) if vocals is not None else mix_rms
    voc_ratio = voc_rms / (mix_rms + 1e-9)
    sung = voc_ratio > max(0.12, 0.35 * float(np.median(voc_ratio)))
    clusters = {}
    for i, s in enumerate(segs):
        c = clusters.setdefault(s["cluster"], {"count": 0, "energy": 0.0, "sung": 0, "first": i})
        c["count"] += 1
        c["energy"] += mix_rms[i]
        c["sung"] += int(sung[i])
    for c in clusters.values():
        c["energy"] /= c["count"]
    repeated_sung = [k for k, c in clusters.items() if c["count"] >= 2 and c["sung"] >= 1]
    chorus = max(repeated_sung, key=lambda k: clusters[k]["energy"] * clusters[k]["count"], default=None)
    verse_candidates = [k for k in repeated_sung if k != chorus]
    verse = min(verse_candidates, key=lambda k: clusters[k]["first"], default=None)

    names = []
    for i, s in enumerate(segs):
        c = s["cluster"]
        if i == 0 and not sung[i] and s["end"] - s["start"] < 40:
            name = "Intro"
        elif i == len(segs) - 1 and (not sung[i] or clusters[c]["count"] == 1):
            name = "Final"
        elif c == chorus:
            name = "Refrão"
        elif c == verse:
            name = "Verso"
        elif not sung[i]:
            name = "Instrumental"
        elif clusters[c]["count"] == 1 and s["start"] > duration * 0.4:
            name = "Ponte"
        elif chorus is not None and i + 1 < len(segs) and segs[i + 1]["cluster"] == chorus and s["end"] - s["start"] < 25:
            name = "Pré-refrão"
        else:
            name = "Verso"
        names.append(name)
    out: list[dict] = []
    for s, n in zip(segs, names):
        if out and out[-1]["label"] == n:
            out[-1]["end"] = round(s["end"], 3)
        else:
            out.append({"start": round(s["start"], 3), "end": round(s["end"], 3), "label": n})
    return out


# ---------------------------------------------------------------- pedido completo

def _normalized(x: np.ndarray, peak: float = 0.9) -> np.ndarray:
    m = float(np.max(np.abs(x))) if x.size else 0.0
    return x if m < 1e-5 else (x * (peak / m)).astype(np.float32)


def analyze(progress_factory, params: dict) -> dict:
    mix_path = Path(params["input"])
    stems_dir = Path(params["stemsDir"]) if params.get("stemsDir") else None
    vocals_file = params.get("vocals")          # nome do arquivo da voz (ou voz principal + backing)
    progress = progress_factory([("load", "Lendo", 1), ("beats", "Detectando batidas", 2),
                                 ("chords", "Detectando acordes", 4), ("key", "Tonalidade", 1),
                                 ("sections", "Partes da música", 3)])
    with progress.step("load"):
        mix = audio.read(mix_path)
        vocals = None
        if stems_dir and vocals_file:
            files = vocals_file if isinstance(vocals_file, list) else [vocals_file]
            parts = [audio.read(stems_dir / f) * g for f, g in zip(files, params.get("vocalsGain", [1.0] * len(files)))]
            vocals = sum(parts) if parts else None
        harmonic = mix - vocals if vocals is not None else mix
        work = Path(params.get("workDir") or mix_path.parent)
        # detectores sofrem com gravação baixa: normaliza o pico antes de analisar
        harmonic_path = work / ".harmonic.wav"
        audio.write_float_wav(harmonic_path, _normalized(harmonic))
        beats_path = work / ".beats.wav"
        audio.write_float_wav(beats_path, _normalized(mix))
    try:
        with progress.step("beats"):
            b = beats(beats_path)
        with progress.step("chords"):
            ch = chords(harmonic_path, b["beats"])
        with progress.step("key"):
            k = key(harmonic, ch)
        with progress.step("sections"):
            try:
                sec = sections(mix, vocals, b["beats"], b["downbeats"])
            except Exception:
                log.exception("falha nas partes da música")
                sec = []
    finally:
        harmonic_path.unlink(missing_ok=True)
        beats_path.unlink(missing_ok=True)
    return {**b, "chords": ch, "key": k, "sections": sec, "duration": round(len(mix) / audio.SAMPLE_RATE, 3)}
