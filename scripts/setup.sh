#!/bin/zsh
# 初回セットアップ: Python 仮想環境と依存パッケージ、ローカル AI モデルを用意する
set -e
cd "$(dirname "$0")/.."
command -v uv >/dev/null || brew install uv
command -v ollama >/dev/null || brew install ollama
uv venv --python 3.11 .venv
uv pip install --python .venv/bin/python -r requirements.txt
[ -f config.toml ] || cp config.example.toml config.toml
[ -f .env ] || cp .env.example .env
ollama list | grep -q "qwen3:8b" || ollama pull qwen3:8b
echo "✅ セットアップ完了。 ./scripts/run.sh で起動します"
