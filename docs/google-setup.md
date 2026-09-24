# Google 連携の準備

AIエージェントから Google（Gmail・カレンダー・Drive・ドキュメント・スプレッドシート・スライド）を使うための準備です。
使う Google アカウントの種類によって、方法が2つあります。

| | 会社の Google Workspace | 個人の Gmail（@gmail.com） |
|---|---|---|
| 使う MCP サーバー | Google 公式（開発者プレビュー） | 有志の [workspace-mcp](https://github.com/taylorwilsdon/google_workspace_mcp)（MIT、Mac の中で動く） |
| 追加の条件 | Workspace の管理者が開発者プレビューに申し込む | [uv](https://github.com/astral-sh/uv)（`brew install uv`） |
| できること | Gmail の検索・閲覧・下書き、カレンダーの閲覧、Drive・ドキュメント・スプレッドシート・スライドの閲覧 | Gmail の検索・閲覧、カレンダーの閲覧・予定の追加、Drive・ドキュメント・スプレッドシート・スライドの閲覧（Drive はフォルダ作成などの書き込みも選べます） |
| 送信・削除 | しない | しない（Gmail は下書きまで。ドキュメント・スプレッドシート・スライドは読むだけ） |

> **Drive にフォルダを作りたい場合**（提出物の確認などで使います）: `mcp.json` の `google-personal` の `--permissions` を `drive:readonly` から `drive:full` に変え、アプリを起動し直してから、Drive を使う操作を1回頼んでください。ブラウザでログインし直すと書き込みが有効になります。権限を変えた直後は、**認証を始めたプロセスが生きている必要があります**（アプリ本体から頼めば大丈夫です）。

どちらも、最後は AIエージェントの **設定 → 連携 →「Google を追加」** に、Google Cloud で作ったクライアント ID とシークレットを入力します。

> AI を Claude / GPT / Gemini にしている間は、読んだメールやファイルの内容が各社のサーバーに送られます。社外に出したくない場合は、「Google を追加」で **ローカル AI 専用にする** をオンにしてください。

---

## 個人の Gmail の場合

1. **プロジェクトを作る**
   [Google Cloud コンソール](https://console.cloud.google.com/) にログインし、画面上部のプロジェクト選択 →「新しいプロジェクト」で作成します（名前は自由。例: `ai-agent`）。

2. **API を有効にする**
   「API とサービス → ライブラリ」で、次の6つを検索してそれぞれ「有効にする」を押します。
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - Google Docs API
   - Google Sheets API
   - Google Slides API

3. **同意画面を設定する**
   「Google Auth Platform」（または「OAuth 同意画面」）で次のように設定します。
   - ユーザーの種類: **外部**
   - アプリ名・サポートメール: 自由（自分のアドレスで可）
   - **対象 → テストユーザー** に、使う Gmail アドレスを追加

4. **クライアントを作る**
   「クライアント」（または「認証情報 → 認証情報を作成 → OAuth クライアント ID」）で次のように作成します。
   - アプリケーションの種類: **ウェブ アプリケーション**
   - 承認済みのリダイレクト URI: `http://localhost:8000/oauth2callback`

   作成後に表示される **クライアント ID** と **クライアント シークレット** を控えます。

5. **AIエージェントに登録する**
   設定 → 連携 →「Google を追加」→「個人の Gmail など」に、クライアント ID・シークレット・Gmail アドレスを入れて「追加する」を押します。

6. **初めて使うときにログインする**
   「新着メールある？」などと頼むと、ブラウザで Google のログイン画面が開きます。
   「このアプリは Google で確認されていません」と出たら、「詳細」→「（アプリ名）に移動」で進み、許可します。終わったら、もう一度頼んでください。

> **7日ごとにログインが切れる場合**: 同意画面の公開ステータスが「テスト中」のままだと、Google の仕様でログインが7日で切れます。自分だけで使うなら、「対象 → アプリを公開」で「本番環境」にすると切れなくなります（確認前の警告画面は出ます）。

---

## 会社の Google Workspace の場合

Google 公式の Workspace MCP サーバーは **開発者プレビュー** です。Workspace のアカウントが必要で、個人の Gmail では使えません。プレビュー中の機能は、顧客に提供しないという規約があります。

1. **開発者プレビューに申し込む**（Workspace の管理者が行う）
   [Google Workspace Developer Preview Program](https://developers.google.com/workspace/preview) から申し込みます。承認まで数日かかります。

2. **プロジェクトを作る**
   会社の Google アカウントで [Google Cloud コンソール](https://console.cloud.google.com/) にログインし、新しいプロジェクトを作ります。

3. **API と MCP サービスを有効にする**
   [gcloud CLI](https://cloud.google.com/sdk/docs/install) で、次を実行します（`PROJECT_ID` は作ったプロジェクトの ID）。

   ```bash
   gcloud services enable gmail.googleapis.com drive.googleapis.com docs.googleapis.com sheets.googleapis.com slides.googleapis.com calendar-json.googleapis.com gmailmcp.googleapis.com drivemcp.googleapis.com docsmcp.googleapis.com sheetsmcp.googleapis.com slidesmcp.googleapis.com calendarmcp.googleapis.com --project=PROJECT_ID
   ```

   コンソールの「API とサービス → ライブラリ」から1つずつ有効にしても構いません。

4. **同意画面を設定する**
   - ユーザーの種類: **内部**（社内だけで使うので、Google の審査は不要で、7日の期限もありません）
   - アプリ名・サポートメール: 自由

5. **クライアントを作る**
   - アプリケーションの種類: **ウェブ アプリケーション**
   - 承認済みのリダイレクト URI: `http://127.0.0.1:8723/oauth2callback`

   作成後に表示される **クライアント ID** と **クライアント シークレット** を控えます。

6. **AIエージェントに登録してログインする**
   設定 → 連携 →「Google を追加」→「会社の Google Workspace」にクライアント ID・シークレットを入れ、使うサービスを選んで「追加する」を押します。
   次に、同じ画面の「ログイン」の欄にある **google-work の「ログイン」** を押し、ブラウザで会社のアカウントでログインします。

> 会社の管理者が、外部アプリから Google のデータへのアクセスを制限している場合は、管理コンソールでこのクライアント ID を許可してもらう必要があります。

---

## 設定ファイルに直接書く場合

「Google を追加」は、`~/Library/Application Support/AIAgent/mcp.json` に次のような設定を書き足しています。手で編集しても同じです。

```json
{
  "mcpServers": {
    "google-work-gmail": { "url": "https://gmailmcp.googleapis.com/mcp/v1", "oauth": "google-work" },
    "google-personal": {
      "command": "uvx",
      "args": ["workspace-mcp", "--single-user", "--tool-tier", "core", "--permissions",
               "gmail:drafts", "calendar:full", "drive:readonly", "docs:readonly", "sheets:readonly", "slides:readonly"],
      "env": { "GOOGLE_OAUTH_CLIENT_ID": "...", "GOOGLE_OAUTH_CLIENT_SECRET": "...",
               "USER_GOOGLE_EMAIL": "you@gmail.com", "OAUTHLIB_INSECURE_TRANSPORT": "1" }
    }
  },
  "oauth": {
    "google-work": { "clientId": "...", "clientSecret": "...",
                     "scopes": ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"] }
  }
}
```

- `oauth` に書いたログイン設定は、複数のサーバーで共有できます（ログインは1回で済む）
- ログインで得たトークンは Mac のキーチェーンに保存され、期限が切れる前に自動で更新されます
