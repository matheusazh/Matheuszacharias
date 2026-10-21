"""Canal JSON-lines com o app e relatório de progresso.

O stdout real fica reservado ao protocolo. Tudo que bibliotecas imprimirem (Python ou C)
vai para o stderr, que o app grava no log do motor.
"""

import json
import os
import sys
import threading
import time
from contextlib import contextmanager


class Channel:
    def __init__(self):
        protocol_fd = os.dup(1)
        os.dup2(2, 1)
        sys.stdout = sys.stderr
        self._out = os.fdopen(protocol_fd, "w", buffering=1, encoding="utf-8")
        self._lock = threading.Lock()

    def send(self, message: dict):
        line = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            self._out.write(line + "\n")
            self._out.flush()


class Cancelled(Exception):
    pass


class Progress:
    """Progresso de um pedido dividido em etapas com peso.

    Cada etapa pode ter várias barras internas (tqdm) em sequência; `bars` diz quantas
    são esperadas, para a fração não voltar quando uma nova barra começa.
    """

    def __init__(self, channel: Channel, request_id: str, steps: list[tuple[str, str, float]]):
        self.channel = channel
        self.request_id = request_id
        self.steps = steps
        total = sum(weight for _, _, weight in steps) or 1.0
        self.weights = {key: weight / total for key, _, weight in steps}
        self.labels = {key: label for key, label, _ in steps}
        self.done = 0.0
        self.current = None
        self.bars_expected = 1
        self.bars_done = 0
        self.bar_fraction = 0.0
        self.step_fraction = 0.0
        self._last_emit = 0.0

    @contextmanager
    def step(self, key: str, bars: int = 1):
        self.current = key
        self.bars_expected = max(1, bars)
        self.bars_done = 0
        self.bar_fraction = 0.0
        self.step_fraction = 0.0
        self._emit(force=True)
        try:
            yield self
        finally:
            self.done += self.weights.get(key, 0.0)
            self.current = None
            self._emit(force=True)

    # Chamado pelas barras tqdm substituídas
    def bar_started(self):
        if self.bar_fraction > 0:
            self.bars_done = min(self.bars_expected - 1, self.bars_done + 1)
        self.bar_fraction = 0.0

    def bar_update(self, fraction: float):
        self.bar_fraction = min(1.0, max(0.0, fraction))
        frac = (self.bars_done + self.bar_fraction) / self.bars_expected
        self.step_fraction = max(self.step_fraction, min(1.0, frac))
        self._emit()

    def set_fraction(self, fraction: float):
        self.step_fraction = max(self.step_fraction, min(1.0, fraction))
        self._emit()

    def overall(self) -> float:
        running = self.weights.get(self.current, 0.0) * self.step_fraction if self.current else 0.0
        return min(1.0, self.done + running)

    def _emit(self, force: bool = False):
        now = time.monotonic()
        if not force and now - self._last_emit < 0.15:
            return
        self._last_emit = now
        self.channel.send({
            "id": self.request_id,
            "event": "progress",
            "step": self.current,
            "label": self.labels.get(self.current, ""),
            "fraction": round(self.overall(), 4),
        })


_active: Progress | None = None


def set_active(progress: Progress | None):
    global _active
    _active = progress


class Bar:
    """Substituto mínimo do tqdm que repassa o avanço para o progresso ativo."""

    def __init__(self, iterable=None, total=None, *args, **kwargs):
        self.iterable = iterable
        if total is None and iterable is not None and hasattr(iterable, "__len__"):
            total = len(iterable)
        self.total = total
        self.n = 0
        self.tracked = bool(total) and total >= 2
        if _active and self.tracked:
            _active.bar_started()

    def __iter__(self):
        for item in self.iterable:
            yield item
            self.update(1)

    def __len__(self):
        return self.total or 0

    def update(self, n=1):
        self.n += n
        if _active and self.tracked:
            _active.bar_update(self.n / self.total)

    def close(self):
        pass

    def refresh(self, *args, **kwargs):
        pass

    def set_description(self, *args, **kwargs):
        pass

    def set_postfix(self, *args, **kwargs):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    # o resto da API do tqdm vira no-op (huggingface_hub, thread_map etc. chamam métodos variados)
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *args, **kwargs: None

    _lock = None

    @classmethod
    def get_lock(cls):
        if cls._lock is None:
            cls._lock = threading.RLock()
        return cls._lock

    @classmethod
    def set_lock(cls, lock):
        cls._lock = lock

    @classmethod
    def write(cls, *args, **kwargs):
        pass


def patch_tqdm():
    """Troca o tqdm dos módulos do audio-separator pela Bar acima."""
    import types

    from audio_separator.separator import separator as sep_module
    from audio_separator.separator.architectures import mdx_separator, mdxc_separator, vr_separator
    from audio_separator.separator.uvr_lib_v5.demucs import apply as demucs_apply
    from audio_separator.separator.uvr_lib_v5.demucs import utils as demucs_utils

    for module in (sep_module, mdx_separator, mdxc_separator, vr_separator):
        module.tqdm = Bar
    shim = types.SimpleNamespace(tqdm=Bar)
    demucs_apply.tqdm = shim
    demucs_utils.tqdm = shim
