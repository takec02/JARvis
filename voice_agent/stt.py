"""音声認識: mlx-whisper (Apple Silicon の GPU で動く Whisper)。"""
from __future__ import annotations

import numpy as np

# 無音や雑音に対して Whisper がよく出す幻聴フレーズ
_HALLUCINATIONS = (
    "ご視聴ありがとうございました", "ご清聴ありがとうございました", "チャンネル登録",
    "Thank you for watching", "字幕", "by H.",
)


class Transcriber:
    def __init__(self, cfg: dict):
        import mlx_whisper

        self._mlx = mlx_whisper
        self.model = cfg["stt"]["model"]
        self.language = cfg["stt"]["language"]

    def warmup(self):
        self.transcribe(np.zeros(16000, dtype=np.float32))

    def transcribe(self, audio: np.ndarray) -> str:
        result = self._mlx.transcribe(
            audio, path_or_hf_repo=self.model, language=self.language,
            condition_on_previous_text=False, no_speech_threshold=0.6,
        )
        text = result.get("text", "").strip()
        if any(h in text for h in _HALLUCINATIONS) and len(text) < 30:
            return ""
        return text
