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
    @State private var keys: [BackendKind: String] = [:]
    @State private var tavilyKey = ""
    @State private var saved = false

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
                keyField(.claude, link: "https://console.anthropic.com/settings/keys")
            }
            Section("GPT — 従量課金") {
                TextField("モデル", text: $s.gptModel)
                keyField(.gpt, link: "https://platform.openai.com/api-keys")
            }
            Section("Gemini — 無料枠あり") {
                TextField("モデル", text: $s.geminiModel)
                keyField(.gemini, link: "https://aistudio.google.com/apikey")
            }
            Section {
                HStack {
                    SecureField("API キー", text: $tavilyKey)
                        .onChange(of: tavilyKey) { saved = false }
                    Link("取得", destination: URL(string: "https://app.tavily.com")!)
                }
            } header: {
                Text("Web 検索（Tavily）— 月1,000回まで無料")
            } footer: {
                Text("ローカル・GPT・Gemini のときに使います。Claude のときは Claude 内蔵の Web 検索（1,000回あたり約10ドル）を使います。")
            }
            Section {
                HStack {
                    Text("API キーは Mac のキーチェーンに保存されます。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if saved { Text("保存しました").font(.caption).foregroundStyle(.green) }
                    Button("キーを保存") {
                        for (kind, value) in keys {
                            if let account = kind.keychainAccount { Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: account) }
                        }
                        Keychain.set(tavilyKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "tavily")
                        saved = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for kind in BackendKind.allCases {
                if let account = kind.keychainAccount { keys[kind] = Keychain.get(account) ?? "" }
            }
            tavilyKey = Keychain.get("tavily") ?? ""
        }
    }

    private func keyField(_ kind: BackendKind, link: String) -> some View {
        HStack {
            SecureField("API キー", text: Binding(get: { keys[kind] ?? "" }, set: { keys[kind] = $0; saved = false }))
            Link("取得", destination: URL(string: link)!)
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

    var body: some View {
        Form {
            Section {
                if let err = mcp.configError {
                    Text(err).foregroundStyle(.red)
                }
                if mcp.serverNames.isEmpty {
                    Text("まだ読み込まれていません").foregroundStyle(.secondary)
                }
                ForEach(mcp.serverNames, id: \.self) { name in
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

    private func color(_ s: MCPStatus) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .yellow
        case .disabled: .gray
        case .unavailable: .orange
        }
    }
}
