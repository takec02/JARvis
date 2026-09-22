# AIエージェント

Mac に常駐する、ローカル音声対話 AI アシスタント。自分で名前をつけたエージェントに呼びかけるだけで、会話や Mac の操作、Web 検索ができます。

このリポジトリには2つの版があります。

| | Mac アプリ版「AIエージェント」（おすすめ） | Python 版 |
|---|---|---|
| 場所 | [`mac/`](mac/) | このページの以下 |
| 形 | メニューバー常駐 or ウィンドウのネイティブアプリ | ターミナルで動くスクリプト |
| 名前 | **初回起動時に自分で名前をつける**（必須） | 設定ファイルで指定（既定: サスケ） |
| ウェイクワード | 自由に設定（既定は名前）。それ以外の会話には反応しない | 名前（＋設定した別表記） |
| 音声認識 | macOS 内蔵（追加ダウンロードほぼ不要） | Whisper（1.6GB） |
| 動作環境 | macOS 26 以降 | macOS 14 以降 |

## Mac アプリ版「AIエージェント」

中央の幾何学的なコアが、待機・聞き取り・思考・発話に合わせて回転・脈動します。会話は新しいものほど上に現れ、古い発言は下へ押し出されながら、あなたの発言は左へ、AI の発言は右へ流れて消えていきます。

### 使い始めるのに必要なこと

**必須**

| やること | 方法 |
|---|---|
| Mac の条件 | Apple Silicon（M1 以降）、**macOS 26 以降**、ビルドに Xcode（Swift 6） |
| ローカル AI を用意 | [Ollama](https://ollama.com/download) をインストールして起動し、`ollama pull qwen3:8b`（約 5GB） |
| アプリをビルド | 下のコマンドで `/Applications` にインストール |
| 初回設定 | 起動すると表示される画面で、性別・名前・呼ばれ方を決めて「起動する」 |
| マイクの許可 | 初回に出るダイアログで許可（出ないときは「システム設定 → プライバシーとセキュリティ → マイク」） |
| 音声認識モデル | 初回起動時に macOS が自動でダウンロード（数分かかることがあります） |

```bash
cd mac
./build.sh --install   # ビルドして /Applications にインストール・起動
```

**必要に応じて**（すべて「設定」画面から登録。API キーは Mac のキーチェーンに保存されます）

| 使いたい機能 | 必要なもの |
|---|---|
| Web 検索（ローカル・GPT・Gemini 使用時） | [Tavily](https://app.tavily.com) の API キー（月1,000回まで無料、クレジットカード不要）→ 設定 → AI |
| Claude を使う | [Anthropic Console](https://console.anthropic.com/settings/keys) の API キー（従量課金）→ 設定 → AI。Web 検索も使うなら、Console の設定で Web 検索を有効にする |
| GPT を使う | [OpenAI](https://platform.openai.com/api-keys) の API キー（従量課金）→ 設定 → AI |
| Gemini を使う | [Google AI Studio](https://aistudio.google.com/apikey) の API キー（無料枠あり）→ 設定 → AI |
| 自然な声にする | 「システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 → 声を管理」から、男性なら **Otoya**、女性なら **Kyoko** の「拡張」または「プレミアム」を追加（自動で使われます） |
| 音楽の操作 | 初回に「ミュージックを操作する許可」のダイアログが出たら許可 |
| 他のアプリとの連携（MCP） | 連携先の MCP サーバーを設定 → 連携 から追加（下記「MCP サーバーの追加」） |

> Claude Pro / ChatGPT Plus などの月額プランでは API は使えません。API は別契約の従量課金です。

### 機能

- 初回起動時に、まずエージェントの性別（男性・女性で声と話し方が変わる）を選び、名前（必須）とウェイクワード（任意、空欄なら名前）を決めます。名前の初期値は男性なら「サスケ」（猿飛佐助）、女性なら「トモエ」（巴御前）で、自由に変更できます。あなたの呼ばれ方＋敬称（初期値「あるじ」、敬称なし）もここで決めます
- 音声認識が名前を漢字で書き起こしても（「のぶなが」→「信長」）、読みで照合するので反応します
- 表示方法は「ウィンドウ＋Dock」（既定）と「メニューバーのみ」から選べます（設定でいつでも変更可）
- AI はローカル (Ollama) / Claude / GPT / Gemini を設定画面か音声で切り替え。API キーはキーチェーンに保存
- **MCP（Model Context Protocol）対応**: MCP サーバーのツールを、どの AI からでも使えます（下記）
- **Web 検索**:「〇〇を調べて」でインターネットを検索し、ページも読んで答えます。ローカル・GPT・Gemini では [Tavily](https://tavily.com)（月1,000回まで無料、設定 → AI で API キーを登録）、Claude では Claude 内蔵の Web 検索（Anthropic Console で Web 検索を有効にしておく必要あり）を使います
- **天気**: 気象庁のデータで今日・明日の天気・降水確率・予想気温を答えます（市区町村名でも可）。「ウェザーニュースで見せて」でウェザーニュースのページをブラウザで開きます（同サイトは規約で自動取得が禁止されているため、中身は読みに行きません）
- ウェイクワードは**1語で、日常会話に出てこない言葉**がおすすめです。「ヘイ ◯◯」のような短い語を含む言葉は聞き取りが不安定になりがちです。また、人名をウェイクワードにすると、その人物の話題（例:「信長の話」）でも反応します

### MCP サーバーの追加

設定の「連携」タブ →「設定ファイルを開く」で `~/Library/Application Support/AIAgent/mcp.json` を編集し、「再読み込み」を押します。書式は Claude Desktop などと同じ `mcpServers` 形式です。

```json
{
  "mcpServers": {
    "files": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"] },
    "remote": { "url": "http://127.0.0.1:8080/mcp", "headers": { "Authorization": "Bearer ..." } },
    "myapp": { "discovery": "~/Library/Application Support/MyApp/mcp.json" }
  }
}
```

- `command`: コマンドを起動して標準入出力（stdio）で接続
- `url`: Streamable HTTP で接続（`headers` で認証ヘッダーを付けられる）
- `discovery`: 起動中のアプリが書き出す接続情報ファイル（`{"url": ..., "token": ...}`）を読んで接続。アプリの起動ごとにポートやトークンが変わる場合向け
- `"disabled": true` で一時的に無効化。未接続のサーバーには1分ごとにつなぎ直します
- ツールの結果に含まれる指示には従わないよう AI に指示しています。送信・削除など取り消せない操作をするツールを持つサーバーを追加するときは注意してください

---

以下は Python 版の説明です。

- **完全ローカルで動作**（音声認識・AI・音声合成すべて Mac 内。無料・オフライン可）
- **AI を切り替え可能**：ローカル (Ollama) / Claude / GPT / Gemini、ほか OpenAI 互換 API。会話中に「クロードに切り替えて」と話すだけで切り替わる
- **Mac を操作**：時刻・天気・バッテリー、アプリ起動、音量、音楽、Web 検索（ブラウザで開く）、ショートカット.app の実行
- **文ごとに順次読み上げ**るので返事が速い

```
 マイク ─▶ 発話区間検出 ─▶ 音声認識 ─▶ 名前の検出 ─▶ AI (＋ツール) ─▶ 音声合成 ─▶ スピーカー
          WebRTC VAD      mlx-whisper                 Ollama / Claude     macOS say
                          large-v3-turbo              / GPT / Gemini
```

## 動作環境

- Apple Silicon の Mac（M1 以降。メモリ 16GB 推奨）
- macOS 14 以降
- 空き容量 約 8GB（ローカル AI モデル 5GB ＋ 音声認識モデル 1.6GB ＋ Python 環境）

## セットアップ

```bash
git clone https://github.com/takec02/ai-agent-mac.git
cd ai-agent-mac
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

設定した名前（既定は「サスケ」）で呼びかけると「チン」と鳴ります。「サスケ、今何時？」のように続けて言っても、呼んでから話しても大丈夫です。

| 話しかける例 | 動作 |
|---|---|
| 今何時？ / 東京の天気は？ / バッテリーどれくらい？ | 情報を答える |
| Safari 開いて / 音量を 30 にして / 音楽かけて / 次の曲 | Mac を操作 |
| 〇〇について検索して | ブラウザで検索 |
| 「朝のルーティン」を実行して | ショートカット.app を実行 |
| クロードに切り替えて / ジェミニにして / ローカルに戻して | AI を切り替え |
| 会話をリセットして | 会話の記憶を消去 |
| ありがとう / おやすみ | 待機状態に戻る |

音声認識が名前を漢字やひらがなで書き起こす場合（例:「佐助」）は、`config.toml` の `[wake] keywords` に追加してください。

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
tail -f ~/Library/Logs/voice-agent.log  # ログを見る
./scripts/install_launchd.sh uninstall  # 解除
```

launchd から起動したプロセスにはマイクの許可ダイアログが出ないことがあります。ログに認識結果が一切出ず反応しない場合は、先に一度ターミナルから `./scripts/run.sh` を実行してマイクを許可するか、「システム設定 > プライバシーとセキュリティ > マイク」を確認してください。

## カスタマイズ

設定はすべて `config.toml`（`config.example.toml` をコピーしたもの）にあります。

- **声**: `[tts] voice`。「システム設定 > アクセシビリティ > 読み上げコンテンツ > システムの声」から **Kyoko（拡張）** などの高品質な声を追加すると、より自然になります
- **呼ばれ方**: `[assistant] user_title = "殿"` のように指定します（既定は「あるじ」）
- **ローカル AI のモデル**: `[backends.local] model`。`gemma3:12b` など Ollama で入れたものを指定
- **ツールの追加**: `voice_agent/tools.py` に関数を書き、`TOOLS` と `_FUNCS` に登録するだけで、全ての AI から使えるようになります。コードを書かなくても、ショートカット.app で作ったショートカットは「〇〇を実行して」で呼べます

## うまく動かないとき

- **反応しない**: 認識結果のログを見て、名前がどう書き起こされているかを確認し、`[wake] keywords` に追加する
- **誤反応が多い**: 日常会話に出てこない名前に変える
- **話し終わる前に切られる**: `[audio] silence_seconds` を 1.2 などに増やす
- **ローカル AI が操作せず「しました」とだけ言う**: 小さいローカルモデルはツールの呼び出しを忘れることがあります。`[backends.local] think = true` にすると正確になりますが、返事がかなり遅くなります。Claude / GPT / Gemini なら確実です
- **ローカル AI の最初の返事が遅い**: モデルの読み込みに 20 秒ほどかかります。以後 30 分はメモリに保持されます（`keep_alive`）

## 使用しているオープンソース

**Mac アプリ版**（音声認識・音声合成は macOS 標準の機能を使用）

| ライブラリ | 用途 | ライセンス |
|---|---|---|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | MCP クライアント | Apache-2.0（一部 MIT） |
| [swift-nio](https://github.com/apple/swift-nio) / [swift-log](https://github.com/apple/swift-log) / [swift-system](https://github.com/apple/swift-system) / [swift-collections](https://github.com/apple/swift-collections) / [swift-atomics](https://github.com/apple/swift-atomics) | MCP SDK の依存 | Apache-2.0 |
| [EventSource](https://github.com/mattt/eventsource) | MCP SDK の依存（SSE） | MIT |

**Python 版**

| ライブラリ | 用途 | ライセンス |
|---|---|---|
| [mlx-whisper](https://github.com/ml-explore/mlx-examples) / [Whisper](https://github.com/openai/whisper) | 音声認識 | MIT |
| [py-webrtcvad](https://github.com/wiseman/py-webrtcvad) | 発話区間検出 | MIT |
| [sounddevice](https://github.com/spatialaudio/python-sounddevice) | マイク入力 | MIT |
| [Ollama](https://github.com/ollama/ollama) | ローカル LLM 実行 | MIT |
| [Qwen3](https://github.com/QwenLM/Qwen3) | ローカル LLM | Apache-2.0 |

**利用している外部データ・サービス**

| サービス | 用途 | 条件 |
|---|---|---|
| [気象庁](https://www.jma.go.jp/) | 天気予報 | [政府標準利用規約](https://www.jma.go.jp/jma/kishou/info/coment.html)に基づき出典を明記して利用 |
| [Tavily](https://tavily.com) | Web 検索 | 利用者自身の API キーで利用 |

## ライセンス

MIT（このリポジトリのコード）。
