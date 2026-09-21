import Foundation
import Observation
import Security
import ServiceManagement

enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .menuBar: "メニューバーのみ"
        case .window: "ウィンドウ＋Dock"
        }
    }
}

enum BackendKind: String, CaseIterable, Identifiable {
    case local, claude, gpt, gemini
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: "ローカル (Ollama)"
        case .claude: "Claude"
        case .gpt: "GPT"
        case .gemini: "Gemini"
        }
    }
    var shortLabel: String {
        switch self {
        case .local: "ローカル"
        case .claude: "Claude"
        case .gpt: "GPT"
        case .gemini: "Gemini"
        }
    }
    /// 音声で「〇〇に切り替えて」と言われたときに照合する表記
    var spokenAliases: [String] {
        switch self {
        case .local: ["ローカル", "オラマ", "ollama", "local"]
        case .claude: ["クロード", "claude"]
        case .gpt: ["gpt", "ジーピーティー", "チャットgpt", "openai"]
        case .gemini: ["ジェミニ", "gemini"]
        }
    }
    var keychainAccount: String? {
        switch self {
        case .local: nil
        case .claude: "anthropic"
        case .gpt: "openai"
        case .gemini: "gemini"
        }
    }
}

/// UserDefaults に保存される設定。API キーだけはキーチェーンに保存する。
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var agentName: String { didSet { d.set(agentName, forKey: "agentName") } }
    /// 呼びかけの言葉。空なら名前を使う
    var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
    var wakeAliases: String { didSet { d.set(wakeAliases, forKey: "wakeAliases") } }
    var userTitle: String { didSet { d.set(userTitle, forKey: "userTitle") } }
    var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: "displayMode") } }
    var backend: BackendKind { didSet { d.set(backend.rawValue, forKey: "backend") } }
    var ollamaModel: String { didSet { d.set(ollamaModel, forKey: "ollamaModel") } }
    var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    var gptModel: String { didSet { d.set(gptModel, forKey: "gptModel") } }
    var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    var followupSeconds: Double { didSet { d.set(followupSeconds, forKey: "followupSeconds") } }
    var chime: Bool { didSet { d.set(chime, forKey: "chime") } }

    private init() {
        agentName = d.string(forKey: "agentName") ?? ""
        wakeWord = d.string(forKey: "wakeWord") ?? ""
        wakeAliases = d.string(forKey: "wakeAliases") ?? ""
        userTitle = d.string(forKey: "userTitle") ?? ""
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "") ?? .menuBar
        backend = BackendKind(rawValue: d.string(forKey: "backend") ?? "") ?? .local
        ollamaModel = d.string(forKey: "ollamaModel") ?? "qwen3:8b"
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-opus-5"
        gptModel = d.string(forKey: "gptModel") ?? "gpt-5-mini"
        geminiModel = d.string(forKey: "geminiModel") ?? "gemini-2.5-flash"
        voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.52
        followupSeconds = d.object(forKey: "followupSeconds") as? Double ?? 0
        chime = d.object(forKey: "chime") as? Bool ?? true
    }

    var isNamed: Bool { !agentName.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 実際に使うウェイクワード（未設定なら名前）
    var effectiveWakeWord: String {
        let w = wakeWord.trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? agentName : w
    }

    /// 反応する表記の一覧（ウェイクワード＋別表記）。これ以外の言葉には反応しない
    var wakeWords: [String] {
        let extra = wakeAliases.split(whereSeparator: { ",、，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return ([effectiveWakeWord] + extra).filter { !$0.isEmpty }
    }

    func model(for kind: BackendKind) -> String {
        switch kind {
        case .local: ollamaModel
        case .claude: claudeModel
        case .gpt: gptModel
        case .gemini: geminiModel
        }
    }

    // MARK: ログイン時に起動

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launchAtLogin: \(error)")
            }
        }
    }
}

enum Keychain {
    private static let service = "io.github.takec02.aiagent"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
