# JARvis

Mac に常駐する、ローカル音声対話 AI アシスタント。映画『アイアンマン』の J.A.R.V.I.S. のように、呼びかけるだけで会話や Mac の操作ができます。

このリポジトリには2つの版があります。

| | Mac アプリ版「AIエージェント」（おすすめ） | Python 版 |
|---|---|---|
| 場所 | [`mac/`](mac/) | このページの以下 |
| 形 | メニューバー常駐 or ウィンドウのネイティブアプリ | ターミナルで動くスクリプト |
| 名前 | **初回起動時に自分で名前をつける**（必須） | ジャービス固定 |
| ウェイクワード | 自由に設定（既定は名前）。それ以外の会話には反応しない | "Hey Jarvis" |
| 音声認識 | macOS 内蔵（追加ダウンロードほぼ不要） | Whisper（1.6GB） |
| 動作環境 | macOS 26 以降 | macOS 14 以降 |

## Mac アプリ版「AIエージェント」

中央の幾何学的なコアが、待機・聞き取り・思考・発話に合わせて回転・脈動します。会話は新しいものほど上に現れ、古い発言は下へ押し出されながら、あなたの発言は左へ、AI の発言は右へ流れて消えていきます。

```bash
cd mac
./build.sh --install   # ビルドして /Applications にインストール・起動
```

- 初回起動時に名前（必須）とウェイクワード（任意、空欄なら名前）を決めます
- 表示方法は「メニューバーのみ」「ウィンドウ＋Dock」から選べます（設定でいつでも変更可）
- AI はローカル (Ollama) / Claude / GPT / Gemini を設定画面か音声で切り替え。API キーはキーチェーンに保存
- ウェイクワードは「ジャービス」のような**1語で、日常会話に出てこない言葉**がおすすめです。「ヘイ ◯◯」のような短い語を含む言葉は聞き取りが不安定になりがちです

---

以下は Python 版の説明です。

- **完全ローカルで動作**（音声認識・AI・音声合成すべて Mac 内。無料・オフライン可）
- **AI を切り替え可能**：ローカル (Ollama) / Claude / GPT / Gemini、ほか OpenAI 互換 API。会話中に「クロードに切り替えて」と話すだけで切り替わる
- **Mac を操作**：時刻・天気・バッテリー、アプリ起動、音量、音楽、Web 検索、ショートカット.app の実行
- **自然な会話**：応答後の数秒間はウェイクワードなしで続けて話せる。文ごとに順次読み上げるので返事が速い

```
 マイク ─▶ ウェイクワード ─▶ 発話区間検出 ─▶ 音声認識 ─▶ AI (＋ツール) ─▶ 音声合成 ─▶ スピーカー
          openWakeWord       WebRTC VAD      mlx-whisper   Ollama / Claude     macOS say
          "Hey Jarvis"                       large-v3-turbo / GPT / Gemini
```

## 動作環境

- Apple Silicon の Mac（M1 以降。メモリ 16GB 推奨）
- macOS 14 以降
- 空き容量 約 8GB（ローカル AI モデル 5GB ＋ 音声認識モデル 1.6GB ＋ Python 環境）

## セットアップ

```bash
git clone https://github.com/takec02/JARvis.git
cd JARvis
./scripts/setup.sh
```

`setup.sh` は [uv](https://github.com/astral-sh/uv) と [Ollama](https://ollama.com) を Homebrew で入れ、Python 環境を作り、ローカル AI モデル `qwen3:8b` をダウンロードします。Ollama アプリ（またはサービス: `brew services start ollama`）が起動している必要があります。

## 使い方

```bash
./scripts/run.sh                  # 音声モードで起動
./scripts/run.sh --text           # キーボードで会話（マイクなしで動作確認したいとき）
./scripts/run.sh --backend claude # 起動時の AI を指定
```

初回起動時は音声認識モデル（約 1.6GB）をダウンロードするので数分かかります。マイクの使用許可を求められたら許可してください。

**「Hey Jarvis」** と呼びかけると「チン」と鳴るので、続けて話しかけます。

| 話しかける例 | 動作 |
|---|---|
| 今何時？ / 東京の天気は？ / バッテリーどれくらい？ | 情報を答える |
| Safari 開いて / 音量を 30 にして / 音楽かけて / 次の曲 | Mac を操作 |
| 〇〇について検索して | ブラウザで検索 |
| 「朝のルーティン」を実行して | ショートカット.app を実行 |
| クロードに切り替えて / ジェミニにして / ローカルに戻して | AI を切り替え |
| 会話をリセットして | 会話の記憶を消去 |
| ありがとう / おやすみ | 待機状態に戻る |

### 日本語の「ジャービス」で起動したい場合

`config.toml` の `[wake] mode = "whisper"` にすると、「ジャービス、今何時？」のように日本語の名前で呼べます（常に音声認識を回すため、`openwakeword` モードより電力を使います）。

## AI の切り替えと料金

| 名前 | 中身 | 料金 | 必要なもの |
|---|---|---|---|
| `local` | Ollama（既定: qwen3:8b） | **無料** | なし |
| `gemini` | Google Gemini | **無料枠あり** | [Google AI Studio](https://aistudio.google.com/apikey) の API キー |
| `claude` | Anthropic Claude（既定: Claude Opus 5） | 従量課金 | [Anthropic Console](https://console.anthropic.com/) の API キー |
| `gpt` | OpenAI GPT | 従量課金 | [OpenAI Platform](https://platform.openai.com/api-keys) の API キー |

API キーは `.env` に書きます（`.env.example` 参照）。

> **注意**: Claude Pro / ChatGPT Plus などの月額サブスクリプションでは API は使えません。API は別契約の従量課金です。ただし音声アシスタントの会話は短いので、日常使いなら月数百円程度に収まることが多いです。Claude を安く速く使いたい場合は `config.toml` で `model = "claude-haiku-4-5"` に変更できます。

[Groq](https://console.groq.com/) や [OpenRouter](https://openrouter.ai/) など OpenAI 互換の API なら、`config.toml` に `[backends.名前]` を追加するだけで使えます（`config.example.toml` 参照）。

## 常駐起動（ログイン時に自動起動）

```bash
./scripts/install_launchd.sh            # 登録（落ちても自動で再起動）
tail -f ~/Library/Logs/jarvis.log       # ログを見る
./scripts/install_launchd.sh uninstall  # 解除
```

launchd から起動したプロセスにはマイクの許可ダイアログが出ないことがあります。ログに `wake!` が一切出ず反応しない場合は、先に一度ターミナルから `./scripts/run.sh` を実行してマイクを許可するか、「システム設定 > プライバシーとセキュリティ > マイク」を確認してください。

## カスタマイズ

設定はすべて `config.toml`（`config.example.toml` をコピーしたもの）にあります。

- **声**: `[tts] voice`。「システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声」から **Kyoko（拡張）** などの高品質な声を追加すると、より自然になります
- **呼び名**: `[assistant] user_name = "トニー"` で「トニー様」と呼ばれます
- **ローカル AI のモデル**: `[backends.local] model`。`gemma3:12b` など Ollama で入れたものを指定
- **ツールの追加**: `jarvis/tools.py` に関数を書き、`TOOLS` と `_FUNCS` に登録するだけで、全ての AI から使えるようになります。コードを書かなくても、ショートカット.app で作ったショートカットは「〇〇を実行して」で呼べます

## うまく動かないとき

- **反応しない / 誤反応が多い**: `[wake] threshold` を調整（下げると反応しやすく、上げると誤反応が減る）
- **話し終わる前に切られる**: `[audio] silence_seconds` を 1.2 などに増やす
- **ローカル AI が操作せず「しました」とだけ言う**: 小さいローカルモデルはツールの呼び出しを忘れることがあります。`[backends.local] think = true` にすると正確になりますが、返事がかなり遅くなります。Claude / GPT / Gemini なら確実です
- **ローカル AI の最初の返事が遅い**: モデルの読み込みに 20 秒ほどかかります。以後 30 分はメモリに保持されます（`keep_alive`）

## 使用しているオープンソース

| ライブラリ | 用途 | ライセンス |
|---|---|---|
| [openWakeWord](https://github.com/dscripka/openWakeWord) | ウェイクワード検出 | Apache-2.0（学習済みモデル "hey_jarvis" は **CC BY-NC-SA 4.0 / 非商用**） |
| [mlx-whisper](https://github.com/ml-explore/mlx-examples) / [Whisper](https://github.com/openai/whisper) | 音声認識 | MIT |
| [py-webrtcvad](https://github.com/wiseman/py-webrtcvad) | 発話区間検出 | MIT |
| [Ollama](https://github.com/ollama/ollama) | ローカル LLM 実行 | MIT |
| [Qwen3](https://github.com/QwenLM/Qwen3) | ローカル LLM | Apache-2.0 |
| [sounddevice](https://github.com/spatialaudio/python-sounddevice) | マイク入力 | MIT |

## ライセンス

MIT（このリポジトリのコード）。ウェイクワードの学習済みモデルは非商用ライセンスのため、商用利用する場合は独自のモデルを学習するか `mode = "whisper"` を使ってください。
