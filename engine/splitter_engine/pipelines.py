"""Fluxos de alto nível: separar música e limpar fala."""

from pathlib import Path

import numpy as np

from . import audio, separation
from .protocol import Progress

# Modelos escolhidos no benchmark (ver engine/BENCHMARK.md)
MODELS = {
    "vocals": "model_bs_roformer_ep_317_sdr_12.9755.ckpt",   # voz × instrumental, máxima qualidade
    "multi": "BS-Roformer-SW.ckpt",                            # 6 faixas, máxima qualidade
    "fast": "htdemucs.yaml",                                   # rápido, 2/4 faixas (6 faixas usa o SW, já é rápido)
    "karaoke": "bs_roformer_karaoke_frazer_becruily.ckpt",     # voz principal × backing
    "denoise": "UVR-DeNoise-Lite.pth",                         # reforço barato; a isolação já tira quase todo ruído
    "dereverb": "dereverb_mel_band_roformer_anvuew_sdr_19.1729.ckpt",  # eco de igreja: +6~7 dB
}

STEM_LABELS = {
    "vocals": "Voz", "lead": "Voz principal", "backing": "Backing vocal", "instrumental": "Instrumental",
    "drums": "Bateria", "bass": "Baixo", "guitar": "Guitarra", "piano": "Piano", "other": "Outros",
    "voice": "Voz limpa", "voice_raw": "Voz isolada", "background": "Trilha de fundo",
}


def _stem_entry(outdir: Path, key: str, data: np.ndarray) -> dict:
    name = f"{key}.flac"
    gain = audio.write_stem(outdir / name, data)
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    return {"id": key, "label": STEM_LABELS.get(key, key.title()), "file": name, "gain": round(gain, 6),
            "silent": peak < 1e-4}


def separate_music(progress_factory, params: dict) -> dict:
    source_path = Path(params["input"])
    outdir = Path(params["outdir"])
    outdir.mkdir(parents=True, exist_ok=True)
    work = outdir / ".work"
    work.mkdir(exist_ok=True)
    count = int(params.get("stems", 2))
    backing = bool(params.get("backing", False))
    fast = params.get("quality", "max") == "fast"

    steps = [("load", "Lendo o áudio", 1)]
    if fast:
        steps.append(("separate", "Separando faixas", 10))
    elif count == 2:
        steps.append(("separate", "Separando voz", 12))
    else:
        steps.append(("separate", "Separando instrumentos", 16))
    if backing:
        steps.append(("backing", "Separando backing vocal", 6))
    steps.append(("write", "Gravando faixas", 1))
    progress: Progress = progress_factory(steps)

    with progress.step("load"):
        mix = audio.read(source_path)

    with progress.step("separate"):
        if fast:
            model = MODELS["multi"] if count == 6 else MODELS["fast"]
            raw = separation.run(model, mix, work)
        elif count == 2:
            raw = separation.run(MODELS["vocals"], mix, work)
        else:
            raw = separation.run(MODELS["multi"], mix, work)

    vocals = separation.pick(raw, "vocals")
    if vocals is None:
        vocals = np.zeros_like(mix)
    rest = {k: v for k, v in raw.items() if k != "vocals"}

    stems: dict[str, np.ndarray] = {}
    if backing:
        with progress.step("backing"):
            kar = separation.run(MODELS["karaoke"], vocals, work)
            lead = separation.pick(kar, "vocals", "lead", "lead vocals")
            if lead is None:
                lead = vocals
            stems["lead"] = lead
            stems["backing"] = vocals - lead
    else:
        stems["vocals"] = vocals

    if count == 2:
        inst = separation.pick(rest, "instrumental", "other", "no vocals")
        stems["instrumental"] = inst if inst is not None and len(rest) == 1 else mix - vocals
    else:
        drums = separation.pick(rest, "drums")
        bass = separation.pick(rest, "bass")
        guitar = separation.pick(rest, "guitar")
        piano = separation.pick(rest, "piano")
        other = separation.pick(rest, "other")
        zeros = np.zeros_like(mix)
        drums = zeros if drums is None else drums
        bass = zeros if bass is None else bass
        if count == 6:
            stems["drums"], stems["bass"] = drums, bass
            stems["guitar"] = zeros if guitar is None else guitar
            stems["piano"] = zeros if piano is None else piano
            # "outros" absorve o resíduo, para a soma bater com a mixagem
            stems["other"] = mix - vocals - drums - bass - stems["guitar"] - stems["piano"]
        else:
            stems["drums"], stems["bass"] = drums, bass
            stems["other"] = mix - vocals - drums - bass

    with progress.step("write"):
        entries = [_stem_entry(outdir, key, data) for key, data in stems.items()]
    _cleanup(work)
    return {"stems": entries, "frames": len(mix), "sampleRate": audio.SAMPLE_RATE,
            "loudness": audio.loudness(mix)}


def clean_speech(progress_factory, params: dict) -> dict:
    source_path = Path(params["input"])
    outdir = Path(params["outdir"])
    outdir.mkdir(parents=True, exist_ok=True)
    work = outdir / ".work"
    work.mkdir(exist_ok=True)
    denoise = bool(params.get("denoise", True))
    dereverb = bool(params.get("dereverb", True))

    steps = [("load", "Lendo o áudio", 1), ("isolate", "Isolando a voz", 10)]
    if denoise:
        steps.append(("denoise", "Tirando ruído", 5))
    if dereverb:
        steps.append(("dereverb", "Tirando eco", 5))
    steps.append(("write", "Gravando", 1))
    progress: Progress = progress_factory(steps)

    with progress.step("load"):
        mix = audio.read(source_path)

    with progress.step("isolate"):
        raw = separation.run(MODELS["vocals"], mix, work)
        voice_raw = separation.pick(raw, "vocals")
        if voice_raw is None:
            voice_raw = np.zeros_like(mix)

    voice = voice_raw
    if denoise:
        with progress.step("denoise"):
            out = separation.run(MODELS["denoise"], voice, work)
            cleaned = separation.pick(out, "no noise", "dry", "no_noise")
            if cleaned is not None:
                voice = cleaned
    if dereverb:
        with progress.step("dereverb"):
            out = separation.run(MODELS["dereverb"], voice, work)
            cleaned = separation.pick(out, "no reverb", "noreverb", "no echo", "dry")
            if cleaned is not None:
                voice = cleaned

    with progress.step("write"):
        stems = {"voice": voice, "voice_raw": voice_raw, "background": mix - voice_raw}
        entries = [_stem_entry(outdir, key, data) for key, data in stems.items()]
        levels = {key: audio.loudness(data) for key, data in stems.items()}
        levels["mix"] = audio.loudness(mix)
    _cleanup(work)
    return {"stems": entries, "frames": len(mix), "sampleRate": audio.SAMPLE_RATE, "loudness": levels}


def model_status() -> dict:
    from . import paths
    return {key: paths.has_model(name) for key, name in MODELS.items()}


def _cleanup(work: Path):
    import shutil
    shutil.rmtree(work, ignore_errors=True)
