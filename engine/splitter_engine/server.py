"""Servidor do motor: lê pedidos JSON do stdin (um por linha) e responde no stdout.

Pedido:   {"id": "...", "method": "separate_music", "params": {...}}
Eventos:  {"id": "...", "event": "progress", "step": "...", "label": "...", "fraction": 0.42}
Resposta: {"id": "...", "result": {...}}  ou  {"id": "...", "error": {"message": "...", "type": "..."}}
Ao subir: {"event": "ready", "version": "...", "device": "mps"}

Cancelar = o app encerra o processo e sobe outro (os modelos recarregam em segundos).
"""

import json
import logging
import os
import sys
import time

from . import __version__, paths, protocol


def main():
    channel = protocol.Channel()
    logging.basicConfig(stream=sys.stderr, level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    log = logging.getLogger("splitter")
    paths.prepare()
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    os.environ.setdefault("TORCHINDUCTOR_CACHE_DIR", str(paths.MODELS_DIR.parent / "cache" / "inductor"))
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    # nada pode ser gravado dentro do .app (quebraria a assinatura): caches vão para Application Support
    os.environ.setdefault("NUMBA_CACHE_DIR", str(paths.MODELS_DIR.parent / "cache" / "numba"))

    started = time.time()
    import torch  # noqa: F401  (importa já para o primeiro pedido não esperar)
    from . import analysis, lyrics, pipelines
    protocol.patch_tqdm()

    handlers = {
        "ping": lambda _pf, _p: {"pong": True},
        "separate_music": pipelines.separate_music,
        "clean_speech": pipelines.clean_speech,
        "analyze": analysis.analyze,
        "transcribe": lyrics.transcribe,
        "download_lyrics_model": lyrics.download,
        "status": lambda _pf, _p: {"models": pipelines.model_status(), **lyrics.status()},
    }
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    log.info("motor pronto em %.1fs (device=%s)", time.time() - started, device)
    channel.send({"event": "ready", "version": __version__, "device": device})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            log.error("pedido inválido: %s", line[:200])
            continue
        request_id = request.get("id")
        method = request.get("method")
        if method == "shutdown":
            break
        handler = handlers.get(method)
        if handler is None:
            channel.send({"id": request_id, "error": {"message": f"método desconhecido: {method}", "type": "ValueError"}})
            continue

        def progress_factory(steps, _id=request_id):
            p = protocol.Progress(channel, _id, steps)
            protocol.set_active(p)
            return p

        t0 = time.time()
        try:
            result = handler(progress_factory, request.get("params") or {})
            log.info("%s concluído em %.1fs", method, time.time() - t0)
            channel.send({"id": request_id, "result": result})
        except Exception as exc:  # o app mostra a mensagem; detalhes ficam no log
            log.exception("%s falhou", method)
            channel.send({"id": request_id, "error": {"message": str(exc), "type": type(exc).__name__}})
        finally:
            protocol.set_active(None)

    # os._exit evita travas de finalização do torch/mlx ao sair
    os._exit(0)
