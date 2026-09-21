"""設定ファイル (config.toml) と .env の読み込み。"""
from __future__ import annotations

import os
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

DEFAULTS: dict = {
    "assistant": {
        "name": "ジャービス",
        "user_name": "",
        "backend": "local",
        "followup_seconds": 8.0,
        "history_turns": 10,
    },
    "wake": {
        "mode": "openwakeword",  # "openwakeword" | "whisper"
        "threshold": 0.5,
        "keywords": ["ジャービス", "ジャーヴィス", "じゃーびす", "jarvis"],
        "chime": True,
    },
    "audio": {
        "sample_rate": 16000,
        "vad_aggressiveness": 2,
        "silence_seconds": 0.8,
        "max_record_seconds": 15.0,
        "start_timeout_seconds": 5.0,
        "input_device": "",
    },
    "stt": {
        "model": "mlx-community/whisper-large-v3-turbo",
        "language": "ja",
    },
    "tts": {
        "voice": "Kyoko",
        "rate": 210,
    },
    "backends": {
        "local": {"type": "ollama", "model": "qwen3:8b"},
        "claude": {"type": "anthropic", "model": "claude-opus-5", "effort": "low"},
        "gpt": {"type": "openai", "model": "gpt-5-mini", "api_key_env": "OPENAI_API_KEY"},
        "gemini": {
            "type": "openai",
            "model": "gemini-2.5-flash",
            "base_url": "https://generativelanguage.googleapis.com/v1beta/openai/",
            "api_key_env": "GEMINI_API_KEY",
        },
    },
}


def _merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def load_env(path: Path = ROOT / ".env") -> None:
    """依存を増やさないための最小限の .env ローダー。既存の環境変数は上書きしない。"""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def load_config(path: Path | None = None) -> dict:
    load_env()
    path = path or ROOT / "config.toml"
    if path.exists():
        with open(path, "rb") as f:
            return _merge(DEFAULTS, tomllib.load(f))
    return DEFAULTS
