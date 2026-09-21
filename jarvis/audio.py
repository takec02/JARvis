"""マイク入力・ウェイクワード検出・発話区間の録音。"""
from __future__ import annotations

import collections
import queue
import time

import numpy as np
import sounddevice as sd
import webrtcvad

CHUNK = 1280  # 80ms @16kHz (openWakeWord の推奨フレーム長)
VAD_FRAME = 320  # 20ms @16kHz


class Microphone:
    def __init__(self, cfg: dict):
        a = cfg["audio"]
        self.rate = a["sample_rate"]
        self.vad = webrtcvad.Vad(a["vad_aggressiveness"])
        self.silence_chunks = int(a["silence_seconds"] * self.rate / CHUNK)
        self.max_chunks = int(a["max_record_seconds"] * self.rate / CHUNK)
        self.q: queue.Queue[np.ndarray] = queue.Queue()
        self.stream = sd.InputStream(
            samplerate=self.rate, channels=1, dtype="int16", blocksize=CHUNK,
            device=a["input_device"] or None, callback=self._callback,
        )

    def _callback(self, indata, frames, t, status):
        self.q.put(indata[:, 0].copy())

    def start(self):
        self.stream.start()

    def read(self, timeout: float | None = None) -> np.ndarray | None:
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            return None

    def flush(self):
        """読み上げ中に拾った自分の声などを捨てる。"""
        while not self.q.empty():
            self.q.get_nowait()

    def is_speech(self, chunk: np.ndarray) -> bool:
        frames = chunk.reshape(-1, VAD_FRAME)
        voiced = sum(self.vad.is_speech(f.tobytes(), self.rate) for f in frames)
        return voiced >= len(frames) // 2

    def record_utterance(self, start_timeout: float | None, preroll: list[np.ndarray] | None = None) -> np.ndarray | None:
        """発話の開始を待ち、無音が続くまで録音して float32 配列を返す。

        start_timeout 秒以内に話し始めなければ None。None を渡すと無期限に待つ。
        """
        ring = collections.deque(preroll or [], maxlen=4)  # 話し始めの取りこぼし防止
        deadline = time.monotonic() + start_timeout if start_timeout else None
        voiced: list[np.ndarray] = []
        silent = 0
        while True:
            chunk = self.read(timeout=0.5)
            if chunk is None:
                if deadline and time.monotonic() > deadline and not voiced:
                    return None
                continue
            speech = self.is_speech(chunk)
            if not voiced:
                ring.append(chunk)
                if speech:
                    voiced = list(ring)
                elif deadline and time.monotonic() > deadline:
                    return None
                continue
            voiced.append(chunk)
            silent = 0 if speech else silent + 1
            if silent >= self.silence_chunks or len(voiced) >= self.max_chunks:
                break
        # 有声部分が短すぎるものは雑音として捨てる
        if len(voiced) - silent < 3:
            return None
        return np.concatenate(voiced).astype(np.float32) / 32768.0


class WakeWord:
    """openWakeWord の "hey jarvis" モデルでウェイクワードを検出する。"""

    def __init__(self, threshold: float):
        import openwakeword.utils
        from openwakeword.model import Model

        openwakeword.utils.download_models(["hey_jarvis"])
        self.model = Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")
        self.threshold = threshold

    def detected(self, chunk: np.ndarray) -> bool:
        scores = self.model.predict(chunk)
        if max(scores.values()) >= self.threshold:
            self.model.reset()
            return True
        return False

    def reset(self):
        self.model.reset()
