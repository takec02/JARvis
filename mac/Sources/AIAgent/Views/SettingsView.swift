import AVFoundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "person.crop.circle") }
            AISettings().tabItem { Label("AI", systemImage: "brain") }
            VoiceSettings().tabItem { Label("声", systemImage: "speaker.wave.2") }
            MCPSettings().tabItem { Label("連携", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section("エージェント") {
                LabeledContent("名前") {
                    HStack {
                        TextField("", text: $name).labelsHidden()
                        Button("変更") {
                            s.agentName = name.trimmingCharacters(in: .whitespaces)
                            agent.wakeWordsChanged()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == s.agentName)
                    }
                }
                TextField("ウェイクワード", text: $s.wakeWord, prompt: Text("空欄なら名前（\(s.agentName)）"))
                    .onSubmit { agent.wakeWordsChanged() }
                TextField("ウェイクワードの別表記", text: $s.wakeAliases, prompt: Text("例: サスケ, 佐助"))
                    .onSubmit { agent.wakeWordsChanged() }
                Text("ウェイクワード（または別表記）が聞こえたときだけ反応します。聞き取られにくいときは、読みや別の書き方をカンマ区切りで追加してください。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("あなたの呼ばれ方", text: $s.userTitle, prompt: Text("例: あるじ、殿"))
                Picker("敬称", selection: $s.userHonorific) {
                    ForEach(AppSettings.honorifics, id: \.self) { Text($0.isEmpty ? "なし" : $0).tag($0) }
                }
                Text("「\(s.userAddress)」と呼ばれます。").font(.caption).foregroundStyle(.secondary)
            }
            Section("動作") {
                Picker("表示方法", selection: $s.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: s.displayMode) { _, mode in
                    AppDelegate.applyDisplayMode(mode)
                    if mode == .window { openWindow(id: "main") }
                }
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in s.launchAtLogin = v }
                Toggle("呼びかけに反応したら効果音を鳴らす", isOn: $s.chime)
                Toggle("応答後、ウェイクワードなしで続けて話せる", isOn: Binding(
                    get: { s.followupSeconds > 0 },
                    set: { s.followupSeconds = $0 ? 8 : 0 }
                ))
                if s.followupSeconds > 0 {
                    LabeledContent("続けて話せる時間") {
                        Stepper("\(Int(s.followupSeconds)) 秒", value: $s.followupSeconds, in: 1...30, step: 1)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = agent.settings.agentName
            launchAtLogin = agent.settings.launchAtLogin
        }
    }
}

private struct AISettings: View {
    @Environment(AgentController.self) private var agent
    @State private var tavilyUsage: WebTools.Usage?
    @State private var usageError: String?

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section {
                Picker("使う AI", selection: $s.backend) {
                    ForEach(BackendKind.allCases) { Text($0.label).tag($0) }
                }
                Text("会話中に「クロードに切り替えて」のように話しても変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ローカル (Ollama) — 無料") {
                TextField("モデル", text: $s.ollamaModel)
                Link("Ollama をダウンロード", destination: URL(string: "https://ollama.com/download")!)
            }
            Section("Claude — 従量課金") {
                TextField("モデル", text: $s.claudeModel)
                APIKeyField(account: "anthropic", placeholder: "sk-ant-… を貼り付け", link: "https://console.anthropic.com/settings/keys")
            }
            Section("GPT — 従量課金") {
                TextField("モデル", text: $s.gptModel)
                APIKeyField(account: "openai", placeholder: "sk-… を貼り付け", link: "https://platform.openai.com/api-keys")
            }
            Section("Gemini — 無料枠あり") {
                TextField("モデル", text: $s.geminiModel)
                APIKeyField(account: "gemini", placeholder: "AIza… を貼り付け", link: "https://aistudio.google.com/apikey")
            }
            Section {
                APIKeyField(account: "tavily", placeholder: "tvly-… を貼り付け", link: "https://app.tavily.com") {
                    Task { await refreshUsage() }
                }
                LabeledContent("今月の使用量") {
                    HStack(spacing: 8) {
                        if let u = tavilyUsage {
                            ProgressView(value: Double(min(u.used, u.limit)), total: Double(max(u.limit, 1)))
                                .frame(width: 120)
                                .tint(u.used >= u.limit ? .red : u.used * 10 >= u.limit * 8 ? .orange : .accentColor)
                            Text("\(u.used) / \(u.limit) 回").monospacedDigit()
                        } else {
                            Text(usageError ?? "—").foregroundStyle(.secondary)
                        }
                        Button { Task { await refreshUsage() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("使用量を更新")
                    }
                }
            } header: {
                Text("Web 検索（Tavily）— 月1,000回まで無料")
            } footer: {
                Text("ローカル・GPT・Gemini のときに使います。Claude のときは Claude 内蔵の Web 検索（1,000回あたり約10ドル）を使います。無料枠を使い切ると、翌月の枠が回復するまで検索できません（その間はブラウザで開く検索を提案します）。")
            }
            Section {
                Text("API キーは入力するとすぐに Mac のキーチェーンに保存されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshUsage() }
    }

    private func refreshUsage() async {
        do {
            tavilyUsage = try await WebTools.usage()
            usageError = nil
        } catch {
            tavilyUsage = nil
            usageError = (error as? Tools.ToolError)?.message ?? "取得できません"
        }
    }
}

/// API キーの入力欄。枠付きで、登録済みかどうかと末尾4文字を表示し、入力するとすぐ保存する
private struct APIKeyField: View {
    let account: String
    let placeholder: String
    let link: String
    var onSaved: (() -> Void)?
    @State private var value = ""
    @State private var reveal = false
    @State private var loaded = false

    init(account: String, placeholder: String, link: String, onSaved: (() -> Void)? = nil) {
        self.account = account
        self.placeholder = placeholder
        self.link = link
        self.onSaved = onSaved
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("API キー")
                Spacer()
                if trimmed.isEmpty {
                    Label("未登録", systemImage: "circle.dashed").foregroundStyle(.secondary)
                } else {
                    Label("登録済み（…\(trimmed.suffix(4))）", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Link("キーを取得", destination: URL(string: link)!)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField("", text: $value, prompt: Text(placeholder))
                    } else {
                        SecureField("", text: $value, prompt: Text(placeholder))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .labelsHidden()
                Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(reveal ? "隠す" : "表示する")
                if !trimmed.isEmpty {
                    Button { value = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .help("キーを削除")
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            value = Keychain.get(account) ?? ""
            loaded = true
        }
        .onChange(of: value) {
            guard loaded else { return }
            Keychain.set(trimmed, for: account)
            onSaved?()
        }
    }
}

private struct VoiceSettings: View {
    @Environment(AgentController.self) private var agent
    @State private var tester = Speaker()

    var body: some View {
        @Bindable var s = agent.settings
        Form {
            Section {
                Picker("性別", selection: $s.agentGender) {
                    ForEach(AgentGender.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: s.agentGender) { _, g in
                    // 選んでいた声が別の性別なら、自動選択に戻す
                    if let v = Speaker.japaneseVoices.first(where: { $0.identifier == s.voiceIdentifier }), Speaker.gender(of: v) != g {
                        s.voiceIdentifier = ""
                    }
                }
                Picker("声", selection: $s.voiceIdentifier) {
                    Text("自動（最も自然な\(s.agentGender.label)の声）").tag("")
                    ForEach(Speaker.voices(for: s.agentGender), id: \.identifier) { v in
                        Text("\(v.name)\(qualityLabel(v.quality))").tag(v.identifier)
                    }
                }
                LabeledContent("話す速さ") {
                    Slider(value: $s.speechRate, in: 0.4...0.65)
                }
                HStack {
                    Spacer()
                    Button("試しに聞く") {
                        tester.voiceIdentifier = s.voiceIdentifier
                        tester.gender = s.agentGender
                        tester.rate = Float(s.speechRate)
                        tester.stop()
                        tester.say("はじめまして。\(s.agentName)です。ご用件をどうぞ。")
                    }
                }
            } footer: {
                Text("より自然な声は「システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 → 声を管理」から追加すると選べるようになります。男性なら Otoya、女性なら Kyoko の「拡張」や「プレミアム」がおすすめです。")
            }
        }
        .formStyle(.grouped)
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: "（プレミアム）"
        case .enhanced: "（拡張）"
        default: ""
        }
    }
}

/// MCP サーバー（右筆・Google Drive など外部ツール）との連携状況
private struct MCPSettings: View {
    @State private var mcp = MCPManager.shared
    @State private var reloading = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                if let err = mcp.configError {
                    Text(err).foregroundStyle(.red)
                }
                if visibleServers.isEmpty {
                    Text("MCP サーバーはまだ登録されていません").foregroundStyle(.secondary)
                }
                ForEach(visibleServers, id: \.self) { name in
                    let st = mcp.status[name] ?? .connecting
                    DisclosureGroup {
                        let tools = mcp.toolNames(of: name)
                        if tools.isEmpty {
                            Text("ツールなし").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(tools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Circle().fill(color(st)).frame(width: 8, height: 8)
                            Text(name == "yuhitsu" ? "右筆 (yuhitsu)" : name)
                            if mcp.isLocalOnly(name) {
                                Label("ローカル AI 専用", systemImage: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("データを Mac の外に出さないため、AI がローカル（Ollama）のときだけ使えます")
                            }
                            Spacer()
                            Text(st.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("MCP サーバー")
            } footer: {
                Text("接続したサーバーのツールは、どの AI からも使えます。未接続のサーバーには1分ごとにつなぎ直します。")
            }
            GoogleSetupSection()
            BusinessServicesSection()
            OtherServicesSection()
            if !mcp.oauthConfigs.isEmpty {
                Section("ログイン") {
                    ForEach(mcp.oauthConfigs.keys.sorted(), id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            if OAuthManager.shared.loggingIn == name {
                                ProgressView().controlSize(.small)
                                Text("ブラウザでログインしてください").font(.caption).foregroundStyle(.secondary)
                            } else if OAuthManager.shared.loggedIn.contains(name) {
                                Label("ログイン済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                Button("ログアウト") { Task { await mcp.logout(name) } }
                            } else {
                                Button("ログイン") {
                                    Task {
                                        do { try await mcp.login(name); loginError = nil } catch { loginError = error.localizedDescription }
                                    }
                                }
                            }
                        }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
            }
            Section {
                HStack {
                    Button("設定ファイルを開く") {
                        mcp.ensureConfigFile()
                        NSWorkspace.shared.open(MCPManager.configURL)
                    }
                    Button(reloading ? "接続中…" : "再読み込み") {
                        reloading = true
                        Task { await mcp.reload(); reloading = false }
                    }
                    .disabled(reloading)
                }
            } footer: {
                Text("設定ファイルは Claude Desktop などと同じ mcpServers 形式です。各 MCP サーバーの説明にある設定例をそのまま追加できます。例: \"files\": { \"command\": \"npx\", \"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"~/Documents\"] }")
            }
        }
        .formStyle(.grouped)
    }

    /// 右筆は、連携版を使っている人だけに関係するので、接続できたときだけ表示する
    private var visibleServers: [String] {
        mcp.serverNames.filter { name in
            guard name == "yuhitsu" else { return true }
            if case .connected = mcp.status[name] { return true }
            return false
        }
    }

    private func color(_ s: MCPStatus) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .yellow
        case .disabled: .gray
        case .unavailable: .orange
        }
    }
}

/// Google を連携先に追加するフォーム（会社の Workspace ＝公式、個人の Gmail ＝有志の MCP サーバー）
private struct GoogleSetupSection: View {
    @State private var mcp = MCPManager.shared
    @State private var workId = ""
    @State private var workSecret = ""
    @State private var workServices: Set<String> = ["gmail", "calendar", "drive", "docs", "sheets", "slides"]
    @State private var workLocal = false
    @State private var personalId = ""
    @State private var personalSecret = ""
    @State private var personalEmail = ""
    @State private var personalLocal = false
    @State private var message: String?

    var body: some View {
        Section {
            DisclosureGroup("会社の Google Workspace（Google 公式）") {
                TextField("OAuth クライアント ID", text: $workId)
                SecureField("クライアント シークレット", text: $workSecret)
                HStack {
                    ForEach(MCPManager.googleServices) { svc in
                        Toggle(svc.label, isOn: Binding(
                            get: { workServices.contains(svc.id) },
                            set: { on in if on { workServices.insert(svc.id) } else { workServices.remove(svc.id) } }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                Toggle("ローカル AI 専用にする", isOn: $workLocal)
                Button("追加する") {
                    Task {
                        do {
                            try await mcp.addGoogleWorkspace(clientId: trim(workId), clientSecret: trim(workSecret), services: workServices, localOnly: workLocal)
                            message = "追加しました。下の「ログイン」から Google にログインしてください。"
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(trim(workId).isEmpty || workServices.isEmpty)
                Text("開発者プレビューへの参加（Workspace の管理者が申し込み）と、Google Cloud での準備が必要です。ログイン後の戻り先に http://127.0.0.1:8723/oauth2callback を登録してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("個人の Gmail など（有志の MCP サーバー）") {
                TextField("OAuth クライアント ID", text: $personalId)
                SecureField("クライアント シークレット", text: $personalSecret)
                TextField("Gmail アドレス", text: $personalEmail)
                Toggle("ローカル AI 専用にする", isOn: $personalLocal)
                Button("追加する") {
                    Task {
                        do {
                            try await mcp.addGooglePersonal(clientId: trim(personalId), clientSecret: trim(personalSecret), email: trim(personalEmail), localOnly: personalLocal)
                            message = "追加しました。初めて使うときに、ブラウザで Google のログイン画面が開きます。"
                        } catch { message = error.localizedDescription }
                    }
                }
                .disabled(trim(personalId).isEmpty || trim(personalSecret).isEmpty || trim(personalEmail).isEmpty)
                Text("Gmail は下書きの作成まで（送信はしない）、カレンダーは予定の追加まで、Drive・ドキュメント・スプレッドシート・スライドは読むだけの権限で動かします。ログイン後の戻り先に http://localhost:8000/oauth2callback を登録してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Google を追加")
        } footer: {
            Link("準備の手順（Google Cloud の設定）", destination: URL(string: "https://github.com/takec02/ai-agent-mac/blob/main/docs/google-setup.md")!)
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Backlog・kintone・Salesforce を連携先に追加するフォーム（各社公式の MCP サーバー）
private struct BusinessServicesSection: View {
    @State private var mcp = MCPManager.shared
    @State private var backlogDomain = ""
    @State private var backlogKey = ""
    @State private var kintoneURL = ""
    @State private var kintoneToken = ""
    @State private var kintoneUser = ""
    @State private var kintonePassword = ""
    @State private var sfServerURL = ""
    @State private var sfDomain = ""
    @State private var sfClientId = ""
    @State private var sfSecret = ""
    @State private var message: String?

    var body: some View {
        Section {
            DisclosureGroup("Backlog") {
                TextField("スペースのドメイン", text: $backlogDomain, prompt: Text("例: example.backlog.com"))
                SecureField("API キー", text: $backlogKey)
                Button("追加する") {
                    run("Backlog を追加しました。") { try await mcp.addBacklog(domain: trim(backlogDomain), apiKey: trim(backlogKey)) }
                }
                .disabled(trim(backlogDomain).isEmpty || trim(backlogKey).isEmpty)
                note("API キーは Backlog の「個人設定 → API」で発行します。課題の登録・更新などの書き込みは、実行前に確認します。")
            }
            DisclosureGroup("kintone") {
                TextField("kintone の URL", text: $kintoneURL, prompt: Text("例: https://example.cybozu.com"))
                SecureField("API トークン（複数ならカンマ区切り）", text: $kintoneToken)
                TextField("または ログイン名", text: $kintoneUser)
                SecureField("パスワード", text: $kintonePassword)
                Button("追加する") {
                    run("kintone を追加しました。") {
                        try await mcp.addKintone(baseURL: trim(kintoneURL), apiToken: trim(kintoneToken), username: trim(kintoneUser), password: kintonePassword)
                    }
                }
                .disabled(trim(kintoneURL).isEmpty || (trim(kintoneToken).isEmpty && trim(kintoneUser).isEmpty))
                note("API トークンは、使うアプリの「設定 → API トークン」で発行します（そのアプリだけに権限を絞れるのでおすすめ）。レコードの追加・更新・削除などは、実行前に確認します。")
            }
            DisclosureGroup("Salesforce") {
                TextField("MCP サーバーの URL", text: $sfServerURL, prompt: Text("Salesforce の設定画面に表示される URL"))
                TextField("My Domain", text: $sfDomain, prompt: Text("例: example.my.salesforce.com"))
                TextField("コンシューマ鍵（クライアント ID）", text: $sfClientId)
                SecureField("コンシューマの秘密（任意）", text: $sfSecret)
                Button("追加する") {
                    run("Salesforce を追加しました。下の「ログイン」から Salesforce にログインしてください。") {
                        try await mcp.addSalesforce(serverURL: trim(sfServerURL), myDomain: trim(sfDomain), clientId: trim(sfClientId), clientSecret: trim(sfSecret))
                    }
                }
                .disabled(trim(sfServerURL).isEmpty || trim(sfDomain).isEmpty || trim(sfClientId).isEmpty)
                note("Enterprise Edition 以上、または無料の Developer Edition で使えます。管理者が「設定 → API カタログ → MCP サーバー」でサーバーを有効にし、外部クライアントアプリ（スコープ mcp_api と refresh_token、PKCE 有効、コールバック URL http://127.0.0.1:8723/oauth2callback）を作ってください。")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("業務サービスを追加")
        } footer: {
            Text("API キーやパスワードは Mac のキーチェーンに保存され、設定ファイルには書かれません。初回の起動時に、各社の MCP サーバーを自動でダウンロードします（Node.js が必要）。")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func run(_ done: String, _ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); message = done } catch { message = error.localizedDescription }
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Notion・Slack・GitHub などを追加するフォーム（各社公式のリモート MCP サーバー）
private struct OtherServicesSection: View {
    enum Kind: String, CaseIterable, Identifiable {
        case notion, slack, github, freee, hubspot, zapier, figma, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notion: "Notion"
            case .slack: "Slack"
            case .github: "GitHub"
            case .freee: "freee"
            case .hubspot: "HubSpot"
            case .zapier: "Zapier"
            case .figma: "Figma（デスクトップ版）"
            case .custom: "その他（URL を指定）"
            }
        }
        var url: String {
            switch self {
            case .notion: "https://mcp.notion.com/mcp"
            case .slack: "https://mcp.slack.com/mcp"
            case .github: "https://api.githubcopilot.com/mcp/"
            case .freee: "https://mcp.freee.co.jp/mcp"
            case .hubspot: "https://mcp.hubspot.com/"
            case .zapier: "https://mcp.zapier.com/api/v1/connect"
            case .figma: "http://127.0.0.1:3845/mcp"
            case .custom: ""
            }
        }
        /// 入力が必要なもの
        var needsClient: Bool { self == .slack || self == .hubspot }
        var needsToken: Bool { self == .github || self == .zapier }
        var needsLogin: Bool { [.notion, .freee, .slack, .hubspot].contains(self) }
        var note: String {
            switch self {
            case .notion: "「追加する」のあと、下の「ログイン」から Notion にログインします（アプリの登録は自動）。"
            case .freee: "「追加する」のあと、下の「ログイン」から freee にログインします（アプリの登録は自動）。使える機能は契約プランと権限によります。"
            case .slack: "Slack の管理画面でアプリを作り（社内アプリとして、ワークスペース管理者の承認が必要）、リダイレクト URL に http://127.0.0.1:8723/oauth2callback を登録して、クライアント ID とシークレットを入れてください。"
            case .hubspot: "HubSpot の開発者設定で「MCP auth app」を作り、リダイレクト URL に http://127.0.0.1:8723/oauth2callback を登録して、クライアント ID とシークレットを入れてください。"
            case .github: "GitHub の「Settings → Developer settings → Personal access tokens」でトークンを作って入れてください（必要なリポジトリと権限だけに絞るのがおすすめ）。"
            case .zapier: "Zapier の MCP 設定画面で発行される接続トークンを入れてください。アクションの実行は、Zapier のプランのタスク数を使います。"
            case .figma: "Figma デスクトップ版の「Preferences → Enable Dev Mode MCP Server」をオンにしてください（有料プランの Dev または Full の席が必要）。Figma を起動している間だけつながります。"
            case .custom: "MCP 標準のログイン（自動登録）に対応したサーバーなら、URL だけでつながります。"
            }
        }
    }

    @State private var mcp = MCPManager.shared
    @State private var kind: Kind = .notion
    @State private var customName = ""
    @State private var customURL = ""
    @State private var customLogin = true
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var token = ""
    @State private var localOnly = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            Picker("サービス", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: kind) { message = nil }
            if kind == .custom {
                TextField("名前（英数字）", text: $customName, prompt: Text("例: mytool"))
                TextField("MCP サーバーの URL", text: $customURL, prompt: Text("https://..."))
                Toggle("ログインが必要", isOn: $customLogin)
            }
            if kind.needsClient {
                TextField("クライアント ID", text: $clientId)
                SecureField("クライアント シークレット", text: $clientSecret)
            }
            if kind.needsToken {
                SecureField(kind == .github ? "個人用アクセストークン" : "接続トークン", text: $token)
            }
            Toggle("ローカル AI 専用にする", isOn: $localOnly)
            HStack {
                Button(working ? "追加中…" : "追加する", action: add).disabled(working || !ready)
                Spacer()
            }
            Text(kind.note).font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("ほかのサービスを追加")
        } footer: {
            Text("書き込み（メッセージ送信・ページ作成・課題登録など）は、実行前に声か画面で確認します。")
        }
    }

    private var ready: Bool {
        switch kind {
        case .custom: return !trim(customName).isEmpty && !trim(customURL).isEmpty
        case .slack, .hubspot: return !trim(clientId).isEmpty
        case .github, .zapier: return !trim(token).isEmpty
        default: return true
        }
    }

    private func add() {
        let name = kind == .custom ? trim(customName).lowercased() : kind.rawValue
        let url = kind == .custom ? trim(customURL) : kind.url
        let needsLogin = kind == .custom ? customLogin : kind.needsLogin
        working = true
        Task {
            defer { working = false }
            do {
                try await mcp.addRemoteServer(name: name, url: url, needsLogin: needsLogin,
                                              clientId: kind.needsClient ? trim(clientId) : nil,
                                              clientSecret: kind.needsClient ? trim(clientSecret) : nil,
                                              bearerToken: kind.needsToken ? trim(token) : nil,
                                              localOnly: localOnly)
                message = needsLogin ? "追加しました。下の「ログイン」の欄にある「\(name)」の「ログイン」を押してください。" : "追加しました。"
                clientSecret = ""
                token = ""
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
