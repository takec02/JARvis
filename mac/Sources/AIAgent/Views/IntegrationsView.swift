import AppKit
import SwiftUI

// MARK: - サービスの定義（手順画面の中身）

/// 連携できるサービス1つ分の説明と、入力してもらう項目
struct ServiceDef: Identifiable {
    enum FieldKind { case text, secret }
    struct Field: Identifiable {
        let id: String
        let label: String
        let example: String
        var kind: FieldKind = .text
        var optional = false
    }

    let id: String
    let name: String
    let symbol: String
    /// できること（例文つき）
    let summary: String
    let examples: [String]
    /// 用意するもの（手順）
    let steps: [String]
    let helpURL: String?
    let helpLabel: String
    let fields: [Field]
    /// つないだあと、ブラウザでのログインが必要か
    let needsLogin: Bool
    /// 設定ファイル上のサーバー名（Google Workspace は複数になる）
    let serverNames: [String]

    static let all: [ServiceDef] = [
        .init(id: "google-personal", name: "Google", symbol: "g.circle.fill",
              summary: "Gmail・カレンダー・Drive・ドキュメント・スプレッドシート・スライドを使えます。Gmail は下書きまで（送信はしません）、Drive などは読むだけです。",
              examples: ["新着メールある？", "明日の予定は？", "Drive で見積書を探して"],
              steps: ["Google Cloud でプロジェクトを作り、6つの API を有効にする", "同意画面を「外部」で作り、テストユーザーに自分の Gmail を追加", "クライアント（ウェブ アプリケーション）を作り、リダイレクト URI に http://localhost:8000/oauth2callback を登録"],
              helpURL: "https://github.com/takec02/ai-agent-mac/blob/main/docs/google-setup.md", helpLabel: "準備の手順を開く",
              fields: [.init(id: "clientId", label: "クライアント ID", example: "…apps.googleusercontent.com"),
                       .init(id: "clientSecret", label: "クライアント シークレット", example: "GOCSPX-…", kind: .secret),
                       .init(id: "email", label: "Gmail アドレス", example: "you@gmail.com")],
              needsLogin: true, serverNames: ["google-personal"]),
        .init(id: "google-work", name: "Google Workspace（会社）", symbol: "building.2.crop.circle.fill",
              summary: "会社の Google Workspace の Gmail・カレンダー・Drive などを、Google 公式の仕組みで使えます（開発者プレビュー）。",
              examples: ["今週の会議の予定は？", "〇〇さんからのメールを要約して"],
              steps: ["Workspace の管理者が開発者プレビューに申し込む（承認まで数日）", "会社のアカウントで Google Cloud のプロジェクトを作り、API と MCP サービスを有効にする", "同意画面を「内部」で作り、クライアント（ウェブ アプリケーション）のリダイレクト URI に http://127.0.0.1:8723/oauth2callback を登録"],
              helpURL: "https://github.com/takec02/ai-agent-mac/blob/main/docs/google-setup.md", helpLabel: "準備の手順を開く",
              fields: [.init(id: "clientId", label: "クライアント ID", example: "…apps.googleusercontent.com"),
                       .init(id: "clientSecret", label: "クライアント シークレット", example: "GOCSPX-…", kind: .secret)],
              needsLogin: true, serverNames: MCPManager.googleServices.map { "google-work-\($0.id)" }),
        .init(id: "notion", name: "Notion", symbol: "doc.text.fill",
              summary: "Notion のページやデータベースを検索・閲覧・作成できます。",
              examples: ["Notion で先週の議事録を探して", "今日の会議の要約を Notion に保存して"],
              steps: ["Notion のアカウントがあれば、準備はいりません"],
              helpURL: nil, helpLabel: "", fields: [], needsLogin: true, serverNames: ["notion"]),
        .init(id: "slack", name: "Slack", symbol: "number.circle.fill",
              summary: "チャンネルの検索・要約や、メッセージの送信ができます。",
              examples: ["#営業 チャンネルの今日の話題を要約して"],
              steps: ["Slack の管理画面（api.slack.com/apps）で社内アプリを作る", "リダイレクト URL に http://127.0.0.1:8723/oauth2callback を登録", "ワークスペース管理者の承認を受ける"],
              helpURL: "https://api.slack.com/apps", helpLabel: "Slack のアプリ管理を開く",
              fields: [.init(id: "clientId", label: "クライアント ID", example: "1234567890.1234567890"),
                       .init(id: "clientSecret", label: "クライアント シークレット", example: "", kind: .secret)],
              needsLogin: true, serverNames: ["slack"]),
        .init(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
              summary: "リポジトリの Issue・プルリクエスト・コードを検索・閲覧・作成できます。",
              examples: ["自分に割り当てられた Issue を教えて"],
              steps: ["GitHub の Settings → Developer settings → Personal access tokens でトークンを作る（必要なリポジトリと権限だけに絞るのがおすすめ）"],
              helpURL: "https://github.com/settings/personal-access-tokens", helpLabel: "トークンの作成ページを開く",
              fields: [.init(id: "token", label: "個人用アクセストークン", example: "github_pat_…", kind: .secret)],
              needsLogin: false, serverNames: ["github"]),
        .init(id: "freee", name: "freee", symbol: "yensign.circle.fill",
              summary: "会計・請求書・人事労務などのデータを確認・登録できます（使える機能は契約プランと権限によります）。",
              examples: ["〇〇社への請求書は入金済み？"],
              steps: ["freee のアカウントがあれば、準備はいりません"],
              helpURL: nil, helpLabel: "", fields: [], needsLogin: true, serverNames: ["freee"]),
        .init(id: "hubspot", name: "HubSpot", symbol: "person.2.circle.fill",
              summary: "コンタクト・会社・取引などを検索・閲覧・更新できます。",
              examples: ["今月クローズ予定の取引は？"],
              steps: ["HubSpot の開発者設定で「MCP auth app」を作る", "リダイレクト URL に http://127.0.0.1:8723/oauth2callback を登録"],
              helpURL: "https://developers.hubspot.com/mcp", helpLabel: "HubSpot の説明を開く",
              fields: [.init(id: "clientId", label: "クライアント ID", example: ""),
                       .init(id: "clientSecret", label: "クライアント シークレット", example: "", kind: .secret)],
              needsLogin: true, serverNames: ["hubspot"]),
        .init(id: "backlog", name: "Backlog", symbol: "checklist",
              summary: "課題・Wiki・プロジェクトを検索・閲覧・登録できます。",
              examples: ["自分の担当で期限が今週の課題は？"],
              steps: ["Backlog の「個人設定 → API」で API キーを発行する"],
              helpURL: nil, helpLabel: "",
              fields: [.init(id: "domain", label: "スペースのドメイン", example: "example.backlog.com"),
                       .init(id: "apiKey", label: "API キー", example: "", kind: .secret)],
              needsLogin: false, serverNames: ["backlog"]),
        .init(id: "kintone", name: "kintone", symbol: "square.grid.3x3.fill",
              summary: "kintone のアプリのレコードを検索・閲覧・登録できます。",
              examples: ["案件管理アプリで今月受注の案件は？"],
              steps: ["使うアプリの「設定 → API トークン」でトークンを発行する（そのアプリだけに権限を絞れる）"],
              helpURL: nil, helpLabel: "",
              fields: [.init(id: "url", label: "kintone の URL", example: "https://example.cybozu.com"),
                       .init(id: "token", label: "API トークン", example: "複数ならカンマ区切り", kind: .secret)],
              needsLogin: false, serverNames: ["kintone"]),
        .init(id: "salesforce", name: "Salesforce", symbol: "cloud.fill",
              summary: "取引先・商談などのデータを、ログインしたユーザーの権限の範囲で検索・閲覧・更新できます。",
              examples: ["〇〇社の商談の状況は？"],
              steps: ["Enterprise Edition 以上か、無料の Developer Edition が必要", "管理者が「設定 → API カタログ → MCP サーバー」でサーバーを有効にする", "外部クライアントアプリ（スコープ mcp_api と refresh_token、PKCE 有効、コールバック http://127.0.0.1:8723/oauth2callback）を作る"],
              helpURL: nil, helpLabel: "",
              fields: [.init(id: "serverURL", label: "MCP サーバーの URL", example: "Salesforce の設定画面に表示される URL"),
                       .init(id: "domain", label: "My Domain", example: "example.my.salesforce.com"),
                       .init(id: "clientId", label: "コンシューマ鍵", example: ""),
                       .init(id: "clientSecret", label: "コンシューマの秘密", example: "", kind: .secret, optional: true)],
              needsLogin: true, serverNames: ["salesforce"]),
        .init(id: "zapier", name: "Zapier", symbol: "bolt.circle.fill",
              summary: "Zapier につないだ数千のサービスの操作を使えます（公式の連携がないサービスもまとめてつなげる）。",
              examples: ["Chatwork の〇〇ルームに連絡して"],
              steps: ["Zapier の MCP 設定画面で接続トークンを発行する（実行するとプランのタスク数を使います）"],
              helpURL: "https://mcp.zapier.com", helpLabel: "Zapier MCP を開く",
              fields: [.init(id: "token", label: "接続トークン", example: "", kind: .secret)],
              needsLogin: false, serverNames: ["zapier"]),
        .init(id: "figma", name: "Figma", symbol: "paintpalette.fill",
              summary: "開いている Figma のデザインの内容を読み取れます。",
              examples: ["選択しているフレームの構成を説明して"],
              steps: ["Figma デスクトップ版で「Preferences → Enable Dev Mode MCP Server」をオンにする（有料プランの Dev か Full の席が必要）", "Figma を起動している間だけつながります"],
              helpURL: nil, helpLabel: "", fields: [], needsLogin: false, serverNames: ["figma"]),
    ]

    /// 設定ファイル上のサーバー名から、表示するサービスを探す
    static func find(server: String) -> ServiceDef? {
        all.first { $0.serverNames.contains(server) }
    }
}

// MARK: - 連携タブ

struct IntegrationSettings: View {
    @State private var mcp = MCPManager.shared
    @State private var setup: ServiceDef?
    @State private var advanced = false

    /// 表示する連携（Google Workspace は1行にまとめる。右筆はつながっているときだけ）
    private var rows: [String] {
        var seen = Set<String>()
        return mcp.serverNames.compactMap { name in
            if name == "yuhitsu", !isConnected(name) { return nil }
            let key = ServiceDef.find(server: name)?.id ?? name
            return seen.insert(key).inserted ? name : nil
        }
    }

    var body: some View {
        Form {
            Section {
                if rows.isEmpty {
                    Text("まだ何もつながっていません。下の「サービスを追加」から選んでください。")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.self) { name in
                    ServiceRow(name: name, onEdit: { setup = ServiceDef.find(server: name) })
                }
            } header: {
                Text("つながっているサービス")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(ServiceDef.all) { def in
                        Button { setup = def } label: {
                            VStack(spacing: 6) {
                                Image(systemName: def.symbol).font(.system(size: 20))
                                Text(def.name).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                                if isAdded(def) {
                                    Text("追加済み").font(.caption2).foregroundStyle(.green)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("サービスを追加")
            } footer: {
                Text("書き込み（送信・作成・更新・削除）は、実行する前に必ず声か画面で確認します。キーやパスワードは Mac のキーチェーンに保存されます。")
            }

            Section {
                DisclosureGroup("上級者向け", isExpanded: $advanced) {
                    Text("連携の設定は Claude Desktop などと同じ形式のファイル（mcp.json）に保存されています。一覧にないサービスも、このファイルに書けばつなげます。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("設定ファイルを開く") {
                            mcp.ensureConfigFile()
                            NSWorkspace.shared.open(MCPManager.configURL)
                        }
                        Button("読み込み直す") { Task { await mcp.reload() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $setup) { def in
            ServiceSetupSheet(def: def)
        }
    }

    private func isConnected(_ name: String) -> Bool {
        if case .connected = mcp.status[name] { return true }
        return false
    }

    private func isAdded(_ def: ServiceDef) -> Bool {
        def.serverNames.contains { mcp.serverNames.contains($0) }
    }
}

/// つながっているサービスの1行（状態と、その場でできる操作）
private struct ServiceRow: View {
    let name: String
    let onEdit: () -> Void
    @State private var mcp = MCPManager.shared
    @State private var oauth = OAuthManager.shared
    @State private var busy = false
    @State private var note: String?
    @State private var confirmRemove = false

    private var def: ServiceDef? { ServiceDef.find(server: name) }
    private var title: String { name == "yuhitsu" ? "右筆" : (def?.name ?? name) }

    /// 行に出す状態
    private enum Health { case ok(String), needsLogin, working, problem(String) }

    private var health: Health {
        if busy || oauth.loggingIn != nil { return .working }
        if name == "google-personal", !mcp.isGooglePersonalLoggedIn { return .needsLogin }
        if let o = mcp.config(name)?.oauth, !oauth.loggedIn.contains(o) { return .needsLogin }
        switch mcp.status[name] ?? .connecting {
        case .connected(let n): return .ok("つながっています（使える機能 \(n) 個）")
        case .connecting: return .working
        case .disabled: return .problem("オフになっています")
        case .unavailable(let m): return m.contains("ログイン") ? .needsLogin : .problem(m)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: def?.symbol ?? "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.medium))
                        if mcp.isLocalOnly(name) {
                            Label("Mac の外に出さない", systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    statusLabel
                }
                Spacer()
                actionButton
                Menu {
                    if def != nil { Button("設定を変更…", action: onEdit) }
                    Button("つなぎ直す") { Task { await mcp.reload() } }
                    Divider()
                    Button("連携を外す…", role: .destructive) { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("\(title) の連携を外しますか？", isPresented: $confirmRemove) {
            Button("連携を外す", role: .destructive) { Task { try? await mcp.removeServer(name) } }
        } message: {
            Text("保存したキーやログイン情報も、この Mac から消します。")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch health {
        case .ok(let t): Label(t, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .needsLogin: Label("ログインが必要です", systemImage: "person.crop.circle.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
        case .working: Label("確認中…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .problem(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .needsLogin = health {
            Button("ログイン") {
                busy = true
                Task {
                    note = await ServiceConnector.login(name: name)
                    busy = false
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 追加・変更の手順画面

private struct ServiceSetupSheet: View {
    let def: ServiceDef
    @Environment(\.dismiss) private var dismiss
    @State private var mcp = MCPManager.shared
    @State private var values: [String: String] = [:]
    @State private var keepInside = false
    @State private var phase: Phase = .input

    private enum Phase: Equatable {
        case input
        case working(String)
        case done(String)
        case failed(String)
    }

    private var isEditing: Bool { def.serverNames.contains { mcp.serverNames.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: def.symbol).font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    Text(def.name).font(.title2.weight(.semibold))
                    Text(isEditing ? "設定を変更" : "つなぐ").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    block("できること") {
                        Text(def.summary).fixedSize(horizontal: false, vertical: true)
                        if !def.examples.isEmpty {
                            Text("話しかけ方の例: " + def.examples.map { "「\($0)」" }.joined(separator: " "))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    block("用意するもの") {
                        ForEach(Array(def.steps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let url = def.helpURL {
                            Button(def.helpLabel) { NSWorkspace.shared.open(URL(string: url)!) }
                        }
                    }
                    if !def.fields.isEmpty {
                        block("入力する") {
                            ForEach(def.fields) { f in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.label + (f.optional ? "（任意）" : "")).font(.callout)
                                    Group {
                                        if f.kind == .secret {
                                            SecureField("", text: binding(f.id), prompt: Text(secretPrompt(f)))
                                        } else {
                                            TextField("", text: binding(f.id), prompt: Text(f.example))
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                    Toggle(isOn: $keepInside) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("内容を Mac の外に出さない")
                            Text("オンにすると、AI がローカル（Ollama）のときだけ使えます。Claude などには内容を送りません。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer.padding(12)
        }
        // 設定画面（高さ 580）の中に収まる大きさにする。はみ出す分は中ほどがスクロールする
        .frame(width: 490, height: 480)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch phase {
            case .input: EmptyView()
            case .working(let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(m) }
            case .done(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .done = phase {
                    Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(isEditing ? "保存してつなぐ" : "つなぐ", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready || isWorking)
                }
            }
        }
    }

    private var isWorking: Bool { if case .working = phase { return true } else { return false } }

    private var ready: Bool {
        def.fields.allSatisfy { f in
            f.optional || !(values[f.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                || (f.kind == .secret && isEditing)  // 変更時は、秘密の欄を空にしておけば今の値を使う
        }
    }

    private func secretPrompt(_ f: ServiceDef.Field) -> String {
        isEditing ? "保存済み（変えるときだけ入力）" : f.example
    }

    private func block(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
    }

    /// 保存済みの値（秘密以外）を入力欄に入れておく
    private func load() {
        keepInside = def.serverNames.contains { mcp.isLocalOnly($0) && mcp.serverNames.contains($0) } || false
        guard let c = def.serverNames.compactMap({ mcp.config($0) }).first else { return }
        switch def.id {
        case "google-personal":
            values["clientId"] = c.env?["GOOGLE_OAUTH_CLIENT_ID"]
            values["email"] = c.env?["USER_GOOGLE_EMAIL"]
        case "google-work", "slack", "hubspot", "salesforce":
            if let o = c.oauth { values["clientId"] = mcp.oauthConfigs[o]?.clientId }
            if def.id == "salesforce" {
                values["serverURL"] = c.url
                values["domain"] = mcp.oauthConfigs["salesforce"]?.authorizeUrl.flatMap { URL(string: $0)?.host }
            }
        case "backlog": values["domain"] = c.env?["BACKLOG_DOMAIN"]
        case "kintone": values["url"] = c.env?["KINTONE_BASE_URL"]
        default: break
        }
    }

    private func connect() {
        let v = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        Task {
            phase = .working("保存しています…")
            do {
                try await ServiceConnector.save(def: def, values: v, keepInside: keepInside)
                if def.needsLogin {
                    phase = .working("ブラウザでログインしてください。許可すると、ここに戻ってきます…")
                    if let problem = await ServiceConnector.login(name: def.serverNames[0]), !problem.hasPrefix("✓") {
                        phase = .failed(problem)
                        return
                    }
                }
                phase = .working("つながるか確認しています…")
                let result = await ServiceConnector.verify(names: def.serverNames)
                switch result {
                case .success(let count):
                    let ex = def.examples.first.map { "「\($0)」のように話しかけてみてください。" } ?? ""
                    phase = .done("つながりました。使える機能は \(count) 個です。\(ex)")
                case .failure(let e):
                    phase = .failed(e.message)
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 保存・ログイン・確認の処理

@MainActor
enum ServiceConnector {
    struct Problem: Error { let message: String }

    static func save(def: ServiceDef, values v: [String: String], keepInside: Bool) async throws {
        let mcp = MCPManager.shared
        func val(_ k: String) -> String { v[k] ?? "" }
        switch def.id {
        case "google-personal":
            try await mcp.addGooglePersonal(clientId: val("clientId"), clientSecret: val("clientSecret"), email: val("email"), localOnly: keepInside)
        case "google-work":
            try await mcp.addGoogleWorkspace(clientId: val("clientId"), clientSecret: val("clientSecret"),
                                             services: Set(MCPManager.googleServices.map(\.id)), localOnly: keepInside)
        case "backlog":
            try await mcp.addBacklog(domain: val("domain"), apiKey: val("apiKey"))
        case "kintone":
            try await mcp.addKintone(baseURL: val("url"), apiToken: val("token"), username: "", password: "")
        case "salesforce":
            try await mcp.addSalesforce(serverURL: val("serverURL"), myDomain: val("domain"), clientId: val("clientId"), clientSecret: val("clientSecret"))
        default:
            let url = ["notion": "https://mcp.notion.com/mcp", "slack": "https://mcp.slack.com/mcp",
                       "github": "https://api.githubcopilot.com/mcp/", "freee": "https://mcp.freee.co.jp/mcp",
                       "hubspot": "https://mcp.hubspot.com/", "zapier": "https://mcp.zapier.com/api/v1/connect",
                       "figma": "http://127.0.0.1:3845/mcp"][def.id] ?? ""
            try await mcp.addRemoteServer(name: def.id, url: url, needsLogin: def.needsLogin,
                                          clientId: v["clientId"], clientSecret: v["clientSecret"],
                                          bearerToken: v["token"], localOnly: keepInside)
        }
        if keepInside, ["backlog", "kintone", "salesforce"].contains(def.id) {
            try await mcp.setLocalOnly(def.serverNames, true)
        }
    }

    /// ログインする。ブラウザでの許可が終わるまで待つ。問題があれば説明を返す（成功は "✓" で始まる）
    static func login(name: String) async -> String? {
        let mcp = MCPManager.shared
        if name == "google-personal" {
            // 有志の Google サーバーは、読むだけの操作を1回呼ぶと、未ログインならブラウザでログイン画面を開く
            _ = await mcp.call("google-personal__list_calendars", arguments: [String: Any](), localAllowed: true)
            for _ in 0..<90 {  // 最大3分待つ
                if mcp.isGooglePersonalLoggedIn { return "✓ ログインしました" }
                try? await Task.sleep(for: .seconds(2))
            }
            return "ログインが完了しませんでした。ブラウザで許可したか確認して、もう一度「ログイン」を押してください。"
        }
        guard let oauthName = mcp.config(name)?.oauth else { return nil }
        do {
            try await mcp.login(oauthName)
            return "✓ ログインしました"
        } catch {
            return error.localizedDescription
        }
    }

    enum VerifyResult { case success(Int), failure(Problem) }

    static func verify(names: [String]) async -> VerifyResult {
        let mcp = MCPManager.shared
        for _ in 0..<15 {
            var total = 0
            var problem: String?
            for n in names where mcp.serverNames.contains(n) {
                switch mcp.status[n] {
                case .connected(let c): total += c
                case .unavailable(let m): problem = m
                default: break
                }
            }
            if total > 0 { return .success(total) }
            if let problem, !problem.contains("接続中") { return .failure(Problem(message: problem)) }
            try? await Task.sleep(for: .seconds(1))
        }
        return .failure(Problem(message: "時間内につながりませんでした。「つながっているサービス」の状態を確認してください。"))
    }
}
