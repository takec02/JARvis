"""ローカル常駐型の音声対話アシスタント。

    python -m voice_agent                  # 音声モード（名前での呼びかけを待機）
    python -m voice_agent --text           # キーボードで会話（動作確認用）
    python -m voice_agent --backend claude # 起動時の AI を指定
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time

from .config import load_config
from .llm import Backend, make_backend
from .tts import Speaker

BACKEND_ALIASES = {
    "local": r"ローカル|ろーかる|オラマ|ollama|local",
    "claude": r"クロード|くろーど|claude",
    "gpt": r"gpt|ジーピーティー|チャット ?gpt|チャットジーピーティー|openai",
    "gemini": r"ジェミニ|じぇみに|gemini",
}
SWITCH_VERB = re.compile(r"切り替え|切りかえ|変えて|かえて|にして|戻して|もどして|チェンジ|switch", re.I)
RESET = re.compile(r"(会話|履歴|記憶).*(リセット|消して|忘れて)")
STANDBY = re.compile(r"^(ありがとう|おやすみ|スタンバイ|もういい|以上|終わり)")


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


class Agent:
    def __init__(self, cfg: dict, backend_name: str):
        self.cfg = cfg
        self.speaker = Speaker(cfg["tts"]["voice"], cfg["tts"]["rate"])
        self.backends: dict[str, Backend] = {}
        self.history: list[dict] = []
        self.backend_name = backend_name
        self.backend = self._get_backend(backend_name)

    def _get_backend(self, name: str) -> Backend:
        if name not in self.backends:
            self.backends[name] = make_backend(self.cfg, name)
        return self.backends[name]

    def _try_switch(self, text: str) -> bool:
        if not SWITCH_VERB.search(text):
            return False
        for name, pattern in BACKEND_ALIASES.items():
            if name in self.cfg["backends"] and re.search(pattern, text, re.I):
                try:
                    self.backend = self._get_backend(name)
                    self.backend_name = name
                    self.speaker.say(f"{self.backend.label}に切り替えました。")
                    log(f"backend -> {name} ({self.backend.model})")
                except Exception as e:
                    self.speaker.say("切り替えに失敗しました。設定を確認してください。")
                    log(f"backend switch failed: {e}")
                return True
        return False

    def handle(self, text: str) -> bool:
        """1発話を処理する。会話を続けるなら True、スタンバイに戻るなら False。"""
        log(f"you: {text}")
        if STANDBY.search(text) and len(text) < 15:
            self.speaker.say("承知しました。いつでもお呼びください。")
            return False
        if RESET.search(text):
            self.history.clear()
            self.speaker.say("会話の記憶をリセットしました。")
            return True
        if self._try_switch(text):
            return True

        print(f"[{self.backend.label}] ", end="", flush=True)
        try:
            reply = self.speaker.speak_stream(self.backend.respond(self.history, text))
        except Exception as e:
            print()
            log(f"error: {e!r}")
            self.speaker.say("申し訳ありません、AIとの通信でエラーが発生しました。")
            return True
        self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": reply}]
        self.history = self.history[-2 * self.cfg["assistant"]["history_turns"]:]
        return True

    # ---- キーボードモード ----
    def run_text(self):
        log(f"テキストモード / AI: {self.backend.label} ({self.backend.model})  終了は Ctrl+C")
        while True:
            try:
                text = input("\nあなた> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if text:
                self.handle(text)
                self.speaker.wait()

    # ---- 音声モード ----
    def run_voice(self):
        from .audio import Microphone
        from .stt import Transcriber

        wake_cfg = self.cfg["wake"]
        log("音声認識モデルを読み込み中（初回はダウンロードに数分かかります）...")
        stt = Transcriber(self.cfg)
        stt.warmup()
        mic = Microphone(self.cfg)
        name = self.cfg["assistant"]["name"]
        words = [name, *wake_cfg["keywords"]]
        keyword = re.compile("|".join(map(re.escape, [w for w in words if w])), re.I)
        mic.start()

        self.speaker.say(f"{name}、起動しました。")
        self.speaker.wait()
        mic.flush()
        hint = f"「{name}」"
        log(f"待機中… {hint} と呼びかけてください / AI: {self.backend.label} ({self.backend.model})")

        def listen(timeout):
            audio = mic.record_utterance(timeout)
            if audio is None:
                return ""
            t0 = time.monotonic()
            text = stt.transcribe(audio)
            log(f"(認識 {time.monotonic() - t0:.1f}s) {text!r}")
            return text

        def after_speaking():
            self.speaker.wait()
            mic.flush()

        while True:
            # 1) ウェイクワード待ち
            heard = listen(None)
            m = keyword.search(heard)
            if not m:
                continue
            command = (heard[:m.start()] + heard[m.end():]).strip(" 、,。.!！?？")
            log("wake!")
            if wake_cfg["chime"]:
                subprocess.Popen(["afplay", "/System/Library/Sounds/Tink.aiff"])

            # 2) 命令を聞く（「サスケ、今何時？」のように続けて言われた場合はそのまま使う）
            if len(command) < 2:
                command = listen(self.cfg["audio"]["start_timeout_seconds"])
            if not command:
                log("聞き取れませんでした。待機に戻ります")
                continue

            # 3) 応答する（followup_seconds を設定すると、しばらくは呼びかけなしで会話を続けられる）
            while command:
                keep = self.handle(command)
                after_speaking()
                followup = self.cfg["assistant"]["followup_seconds"]
                if not keep or followup <= 0:
                    break
                command = listen(followup)
            log(f"待機中… {hint}")


def main():
    p = argparse.ArgumentParser(description="local voice assistant")
    p.add_argument("--text", action="store_true", help="キーボードで会話する（マイク不要）")
    p.add_argument("--backend", help="起動時の AI (local / claude / gpt / gemini)")
    p.add_argument("--config", help="設定ファイルのパス")
    args = p.parse_args()

    from pathlib import Path

    cfg = load_config(Path(args.config) if args.config else None)
    try:
        agent = Agent(cfg, args.backend or cfg["assistant"]["backend"])
    except Exception as e:
        sys.exit(f"起動に失敗しました: {e}")
    try:
        agent.run_text() if args.text else agent.run_voice()
    except KeyboardInterrupt:
        pass
    finally:
        agent.speaker.stop()


if __name__ == "__main__":
    main()
