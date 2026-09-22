"""AI が呼び出せる Mac 操作ツール。

スキーマは共通の JSON Schema で1回だけ定義し、各バックエンド側で形式を変換する。
シェルを直接実行するツールは意図的に用意していない（音声の聞き間違いで危険な操作をしないため）。
"""
from __future__ import annotations

import datetime as dt
import json
import subprocess
import urllib.parse
import urllib.request


def _run(args: list[str], timeout: float = 10) -> str:
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip() or f"exit {r.returncode}")
    return r.stdout.strip()


def get_datetime() -> str:
    now = dt.datetime.now()
    wd = "月火水木金土日"[now.weekday()]
    return now.strftime(f"%Y年%m月%d日({wd}) %H時%M分")


def open_app(name: str) -> str:
    _run(["open", "-a", name])
    return f"{name} を開きました"


def set_volume(level: int) -> str:
    level = max(0, min(100, int(level)))
    _run(["osascript", "-e", f"set volume output volume {level}"])
    return f"音量を {level} にしました"


def get_battery() -> str:
    return _run(["pmset", "-g", "batt"])


def music_control(action: str) -> str:
    cmds = {"play": "play", "pause": "pause", "next": "next track", "previous": "previous track"}
    if action not in cmds:
        raise ValueError(f"unknown action: {action}")
    _run(["osascript", "-e", f'tell application "Music" to {cmds[action]}'])
    return f"Music: {action}"


def web_search(query: str) -> str:
    url = "https://www.google.com/search?q=" + urllib.parse.quote(query)
    _run(["open", url])
    return f"ブラウザで「{query}」を検索しました"


def get_weather(city: str) -> str:
    fmt = urllib.parse.quote("%l: %C 気温%t 湿度%h 風%w")
    url = f"https://wttr.in/{urllib.parse.quote(city)}?format={fmt}&lang=ja"
    req = urllib.request.Request(url, headers={"User-Agent": "curl"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return r.read().decode().strip()


def run_shortcut(name: str) -> str:
    out = _run(["shortcuts", "run", name], timeout=60)
    return out or f"ショートカット「{name}」を実行しました"


def _s(props: dict, required: list[str] | None = None) -> dict:
    return {"type": "object", "properties": props, "required": required or list(props)}


TOOLS: list[dict] = [
    {"name": "get_datetime", "description": "現在の日付と時刻を取得する", "parameters": _s({})},
    {
        "name": "open_app",
        "description": "Mac のアプリを起動する。name はアプリ名（例: Safari, Music, Finder, カレンダー）",
        "parameters": _s({"name": {"type": "string"}}),
    },
    {
        "name": "set_volume",
        "description": "Mac の出力音量を 0〜100 で設定する",
        "parameters": _s({"level": {"type": "integer", "minimum": 0, "maximum": 100}}),
    },
    {"name": "get_battery", "description": "バッテリー残量と充電状態を取得する", "parameters": _s({})},
    {
        "name": "music_control",
        "description": "音楽（ミュージック.app）の再生操作。例:「音楽かけて」→play、「止めて」→pause、「次の曲」「スキップ」→next、「前の曲」→previous",
        "parameters": _s({"action": {"type": "string", "enum": ["play", "pause", "next", "previous"]}}),
    },
    {
        "name": "web_search",
        "description": "ブラウザで Web 検索を開く（結果は読み上げられない）",
        "parameters": _s({"query": {"type": "string"}}),
    },
    {
        "name": "get_weather",
        "description": "指定した都市の現在の天気を取得する。city はローマ字推奨（例: Tokyo）",
        "parameters": _s({"city": {"type": "string"}}),
    },
    {
        "name": "run_shortcut",
        "description": "macOS のショートカット.app に登録されたショートカットを名前で実行する",
        "parameters": _s({"name": {"type": "string"}}),
    },
]

_FUNCS = {
    "get_datetime": get_datetime,
    "open_app": open_app,
    "set_volume": set_volume,
    "get_battery": get_battery,
    "music_control": music_control,
    "web_search": web_search,
    "get_weather": get_weather,
    "run_shortcut": run_shortcut,
}


def _validate(name: str, args) -> dict:
    spec = next((t for t in TOOLS if t["name"] == name), None)
    if spec is None:
        raise ValueError(f"unknown tool: {name}")
    if isinstance(args, str):
        args = json.loads(args or "{}")
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object")
    schema = spec["parameters"]
    for key in schema["required"]:
        if key not in args:
            raise ValueError(f"missing argument: {key}")
    clean = {}
    for key, prop in schema["properties"].items():
        if key not in args:
            continue
        value = args[key]
        if prop["type"] == "integer":
            try:  # 小さいローカルモデルは "50" のように文字列で渡してくることがある
                value = int(float(value))
            except (TypeError, ValueError):
                raise ValueError(f"bad type for {key}") from None
        elif not isinstance(value, str):
            raise ValueError(f"bad type for {key}")
        if "enum" in prop and value not in prop["enum"]:
            raise ValueError(f"{key} must be one of {prop['enum']}")
        clean[key] = value
    return clean


def execute(name: str, args) -> tuple[str, bool]:
    """ツールを実行して (結果テキスト, エラーかどうか) を返す。"""
    try:
        clean = _validate(name, args)
        return _FUNCS[name](**clean), False
    except Exception as e:  # ツールの失敗は AI に伝えて言い直してもらう
        return f"エラー: {e}", True
