"""音声合成: macOS 標準の `say` を使い、LLM のストリーミング出力を文単位で読み上げる。"""
from __future__ import annotations

import queue
import re
import subprocess
import threading

_SENTENCE_END = re.compile(r"(?<=[。！？!?\n])")
_MARKDOWN = re.compile(r"[*_#`>|~]|\[([^\]]*)\]\([^)]*\)")


def clean(text: str) -> str:
    text = _MARKDOWN.sub(lambda m: m.group(1) or "", text)
    return re.sub(r"\s+", " ", text).strip()


class Speaker:
    def __init__(self, voice: str = "Kyoko", rate: int = 210):
        self.voice, self.rate = voice, rate
        self._q: queue.Queue[str | None] = queue.Queue()
        self._proc: subprocess.Popen | None = None
        self._pending = 0
        self._lock = threading.Lock()
        self._idle = threading.Event()
        self._idle.set()
        threading.Thread(target=self._worker, daemon=True).start()

    def _worker(self):
        while True:
            text = self._q.get()
            if text:
                self._proc = subprocess.Popen(["say", "-v", self.voice, "-r", str(self.rate), text])
                self._proc.wait()
                self._proc = None
            with self._lock:
                self._pending -= 1
                if self._pending <= 0:
                    self._pending = 0
                    self._idle.set()

    def say(self, text: str) -> None:
        text = clean(text)
        if text:
            with self._lock:
                self._pending += 1
                self._idle.clear()
            self._q.put(text)

    def speak_stream(self, chunks) -> str:
        """テキスト断片を受け取りながら、文が完成したものから順に読み上げる。全文を返す。"""
        buf, full = "", ""
        for chunk in chunks:
            print(chunk, end="", flush=True)
            full += chunk
            buf += chunk
            parts = _SENTENCE_END.split(buf)
            for sentence in parts[:-1]:
                self.say(sentence)
            buf = parts[-1]
        self.say(buf)
        print()
        return full

    def wait(self) -> None:
        self._idle.wait()

    def stop(self) -> None:
        with self._lock:
            while not self._q.empty():
                self._q.get_nowait()
                self._pending -= 1
        if self._proc:
            self._proc.terminate()
