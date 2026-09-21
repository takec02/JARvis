import AVFoundation
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("一般", systemImage: "person.crop.circle") }
            AISettings().tabItem { Label("AI", systemImage: "brain") }
            VoiceSettings().tabItem { Label("声", systemImage: "speaker.wave.2") }
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
                TextField("ウェイクワードの別表記", text: $s.wakeAliases, prompt: Text("例: ゲンナイ, げんない"))
                    .onSubmit { agent.wakeWordsChanged() }
                Text("ウェイクワード（または別表記）が聞こえたときだけ反応します。聞き取られにくいときは、読みや別の書き方をカンマ区切りで追加してください。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("あなたの呼ばれ方", text: $s.userTitle, prompt: Text("例: トニー（→「トニー様」）"))
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
                    Text("API キーは Mac のキーチェーンに保存されます。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if saved { Text("保存しました").font(.caption).foregroundStyle(.green) }
                    Button("キーを保存") {
                        for (kind, value) in keys {
                            if let account = kind.keychainAccount { Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: account) }
                        }
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
                Picker("声", selection: $s.voiceIdentifier) {
                    Text("自動（最も高品質な日本語の声）").tag("")
                    ForEach(Speaker.japaneseVoices, id: \.identifier) { v in
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
                        tester.rate = Float(s.speechRate)
                        tester.stop()
                        tester.say("はじめまして。\(s.agentName)です。ご用件をどうぞ。")
                    }
                }
            } footer: {
                Text("より自然な声は「システム設定 → アクセシビリティ → 読み上げコンテンツ → システムの声 → 声を管理」から Kyoko（プレミアム）などを追加すると選べるようになります。")
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
