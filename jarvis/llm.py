"""LLM バックエンド: ローカル (Ollama) / Claude / OpenAI 互換 (GPT・Gemini・Groq など)。

各バックエンドは `respond(history, user_text)` でテキスト断片を順次 yield する。
ツール呼び出しのやりとりはバックエンド内部で完結させ、会話履歴には
ユーザー発話と最終応答のテキストだけを残す（バックエンドを切り替えても履歴を引き継げる）。
"""
from __future__ import annotations

import os
from typing import Iterator

from . import tools

MAX_TOOL_ROUNDS = 5

SYSTEM_PROMPT = """あなたは「{name}」。{user}の Mac 上で常駐する、映画『アイアンマン』のJ.A.R.V.I.S.のような執事型AIアシスタントです。
- 返答は音声で読み上げられる。1〜3文の短い話し言葉で、要点から答える。
- Markdown、箇条書き、絵文字、URL、コードは使わない。数字や記号も読み上げやすく書く。
- 落ち着いた丁寧な口調で、ときどき控えめなユーモアを交えてよい。
- Mac の操作（音量・アプリ起動・音楽など）や情報取得（時刻・天気・バッテリーなど）を頼まれたら、返答する前に必ず該当するツールを呼び出す。ツールを呼ばずに「設定しました」「開きました」などと言ってはいけない。
- ツールで表現できない依頼は、推測せずにできないと伝える。
- 聞き取りミスらしい不自然な文は、意図を推測して短く確認する。"""


def system_prompt(cfg: dict) -> str:
    a = cfg["assistant"]
    user = f"{a['user_name']}様" if a.get("user_name") else "ご主人様"
    return SYSTEM_PROMPT.format(name=a["name"], user=user)


class Backend:
    label = "base"

    def __init__(self, conf: dict, system: str):
        self.conf = conf
        self.system = system
        self.model = conf["model"]

    def respond(self, history: list[dict], user_text: str) -> Iterator[str]:
        raise NotImplementedError


class OllamaBackend(Backend):
    label = "ローカル"

    def __init__(self, conf, system):
        super().__init__(conf, system)
        import ollama

        self.client = ollama.Client(host=conf.get("host", "http://localhost:11434"))
        self.tools = [
            {"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["parameters"]}}
            for t in tools.TOOLS
        ]

    def respond(self, history, user_text):
        messages = [{"role": "system", "content": self.system}, *history, {"role": "user", "content": user_text}]
        for _ in range(MAX_TOOL_ROUNDS):
            calls, text = [], ""
            stream = self.client.chat(
                model=self.model, messages=messages, tools=self.tools, stream=True,
                think=self.conf.get("think", False), keep_alive=self.conf.get("keep_alive", "30m"),
            )
            for chunk in stream:
                msg = chunk.message
                if msg.content:
                    text += msg.content
                    yield msg.content
                if msg.tool_calls:
                    calls.extend(msg.tool_calls)
            if not calls:
                return
            messages.append({"role": "assistant", "content": text, "tool_calls": calls})
            for c in calls:
                result, _ = tools.execute(c.function.name, dict(c.function.arguments or {}))
                messages.append({"role": "tool", "content": result, "tool_name": c.function.name})


class AnthropicBackend(Backend):
    label = "Claude"

    def __init__(self, conf, system):
        super().__init__(conf, system)
        import anthropic

        self.client = anthropic.Anthropic()  # ANTHROPIC_API_KEY などを環境から解決
        self.tools = [
            {"name": t["name"], "description": t["description"], "input_schema": t["parameters"], "eager_input_streaming": True}
            for t in tools.TOOLS
        ]

    def respond(self, history, user_text):
        messages = [*history, {"role": "user", "content": user_text}]
        system = self.system + "\n- Latency-sensitive; begin your visible answer immediately."
        for _ in range(MAX_TOOL_ROUNDS):
            with self.client.beta.messages.stream(
                model=self.model,
                max_tokens=self.conf.get("max_tokens", 8000),
                system=system,
                tools=self.tools,
                messages=messages,
                output_config={"effort": self.conf.get("effort", "low")},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            ) as stream:
                for event in stream:
                    if event.type == "text":
                        yield event.text
                response = stream.get_final_message()

            if response.stop_reason == "refusal":
                yield "申し訳ありません、その依頼にはお応えできません。"
                return
            if response.stop_reason == "pause_turn":
                messages.append({"role": "assistant", "content": response.content})
                continue
            tool_uses = [b for b in response.content if b.type == "tool_use"]
            if not tool_uses:
                return
            if response.stop_reason == "max_tokens":
                yield "応答が長くなりすぎたため中断しました。"
                return
            messages.append({"role": "assistant", "content": response.content})
            results = []
            for b in tool_uses:
                # eager streaming では入力が検証されないので tools.execute 側で型チェックする
                result, is_error = tools.execute(b.name, b.input)
                results.append({"type": "tool_result", "tool_use_id": b.id, "content": result, "is_error": is_error})
            messages.append({"role": "user", "content": results})


class OpenAICompatBackend(Backend):
    """OpenAI, Gemini (無料枠あり), Groq, OpenRouter など OpenAI 互換 API 全般。"""

    def __init__(self, conf, system, label="GPT"):
        super().__init__(conf, system)
        from openai import OpenAI

        self.label = label
        key_env = conf.get("api_key_env", "OPENAI_API_KEY")
        api_key = os.environ.get(key_env)
        if not api_key:
            raise RuntimeError(f"{key_env} が設定されていません (.env に書いてください)")
        self.client = OpenAI(api_key=api_key, base_url=conf.get("base_url"))
        self.tools = [
            {"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["parameters"]}}
            for t in tools.TOOLS
        ]

    def respond(self, history, user_text):
        messages = [{"role": "system", "content": self.system}, *history, {"role": "user", "content": user_text}]
        for _ in range(MAX_TOOL_ROUNDS):
            stream = self.client.chat.completions.create(model=self.model, messages=messages, tools=self.tools, stream=True)
            text, calls = "", {}
            for chunk in stream:
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].delta
                if delta.content:
                    text += delta.content
                    yield delta.content
                for tc in delta.tool_calls or []:
                    c = calls.setdefault(tc.index, {"id": "", "name": "", "arguments": ""})
                    c["id"] = tc.id or c["id"]
                    if tc.function:
                        c["name"] += tc.function.name or ""
                        c["arguments"] += tc.function.arguments or ""
            if not calls:
                return
            messages.append({
                "role": "assistant",
                "content": text or None,
                "tool_calls": [
                    {"id": c["id"], "type": "function", "function": {"name": c["name"], "arguments": c["arguments"] or "{}"}}
                    for c in calls.values()
                ],
            })
            for c in calls.values():
                result, _ = tools.execute(c["name"], c["arguments"])
                messages.append({"role": "tool", "tool_call_id": c["id"], "content": result})


def make_backend(cfg: dict, name: str) -> Backend:
    conf = cfg["backends"].get(name)
    if conf is None:
        raise ValueError(f"backend '{name}' は config.toml にありません")
    system = system_prompt(cfg)
    kind = conf["type"]
    if kind == "ollama":
        return OllamaBackend(conf, system)
    if kind == "anthropic":
        return AnthropicBackend(conf, system)
    if kind == "openai":
        return OpenAICompatBackend(conf, system, label=conf.get("label", name.upper() if name == "gpt" else name.capitalize()))
    raise ValueError(f"unknown backend type: {kind}")
