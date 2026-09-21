import AppKit
import Foundation
import Observation

enum AgentState: Equatable {
    case needsName, starting, idle, listening, thinking, speaking, paused
    case error(String)

    var label: String {
        switch self {
        case .needsName: "名前を設定してください"
        case .starting: "起動中…"
        case .idle: "待機中"
        case .listening: "聞いています"
        case .thinking: "考え中…"
        case .speaking: "話しています"
        case .paused: "マイク停止中"
        case .error(let m): m
        }
    }

    var symbol: String {
        switch self {
        case .needsName, .starting: "circle.dotted"
        case .idle: "circle.hexagonpath"
        case .listening: "circle.hexagonpath.fill"
        case .thinking: "hexagon"
        case .speaking: "hexagon.fill"
        case .paused: "mic.slash"
        case .error: "exclamationmark.triangle"
        }
    }
}

struct ConversationEntry: Identifiable {
    let id = UUID()
    let role: String  // "user" | "assistant" | "system"
    var text: String
}

/// マイク → 呼びかけ検出 → AI → 読み上げ の流れを制御する。
@MainActor @Observable
final class AgentController {
    static let shared = AgentController()

    let settings = AppSettings.shared
    private(set) var state: AgentState = .needsName
    private(set) var liveText = ""
    private(set) var entries: [ConversationEntry] = []
    /// マイクの音量 (0〜1)。画面のアニメーションに使う
    private(set) var level: Double = 0

    private var history: [ChatMessage] = []
    private let listener = SpeechListener()
    private let speaker = Speaker()
    private var started = false
    private var userPaused = false
    /// true の間は呼びかけなしで命令として受け付ける（呼びかけ直後・応答直後）
    private var acceptingCommand = false
    private var timeoutTask: Task<Void, Never>?
    private var chimedForCurrentUtterance = false

    private init() {}

    // MARK: 起動

    func startIfReady() {
        guard settings.isNamed, !started else { return }
        started = true
        state = .starting
        Task {
            guard await SpeechListener.requestPermission() else {
                state = .error("マイクの使用が許可されていません（システム設定 → プライバシーとセキュリティ → マイク）")
                started = false
                return
            }
            listener.onLevel = { [weak self] v in
                Task { @MainActor in
                    guard let self else { return }
                    // 上がるときは速く、下がるときはゆっくり
                    self.level = v > self.level ? v : self.level * 0.8 + v * 0.2
                }
            }
            do {
                try await listener.start(
                    locale: Locale(identifier: "ja-JP"),
                    contextWords: settings.wakeWords,
                    onStatus: { [weak self] msg in self?.state = .error(msg) },
                    onResult: { [weak self] text, isFinal in self?.onTranscript(text, isFinal: isFinal) }
                )
                Log.write("listening started. wake words: \(settings.wakeWords)")
                state = .idle
                await speakAndWait("\(settings.agentName)、起動しました。")
                setIdle()
            } catch {
                Log.write("listener start failed: \(error)")
                state = .error("音声認識を開始できません: \(error.localizedDescription)")
                started = false
            }
        }
    }

    /// 名前や別表記が変わったとき、認識のヒントを更新する
    func wakeWordsChanged() {
        Task { await listener.setContext(settings.wakeWords) }
    }

    func togglePause() {
        userPaused.toggle()
        if userPaused {
            speaker.stop()
            listener.muted = true
            state = .paused
        } else {
            setIdle()
        }
    }

    var isPaused: Bool { userPaused }

    func clearConversation() {
        history.removeAll()
        entries.removeAll()
    }

    // MARK: 音声認識の結果

    private func onTranscript(_ text: String, isFinal: Bool) {
        guard state == .idle || state == .listening else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveText = trimmed
        let matcher = WakeMatcher(words: settings.wakeWords)

        if acceptingCommand {
            state = .listening
            if !isFinal {
                scheduleTimeout(max(settings.followupSeconds, 6))  // 話している間は待ち時間を延長
                return
            }
            let command = matcher.extractCommand(from: trimmed) ?? trimmed
            if command.count >= 2 { handle(command) }
            return
        }

        // 呼びかけ待ち
        guard let command = matcher.extractCommand(from: trimmed) else {
            if isFinal { setIdle() }  // 途中で聞こえたウェイクワードが確定結果で消えた場合も待機に戻す
            return
        }
        if !chimedForCurrentUtterance {
            Log.write("wake word detected")
            chimedForCurrentUtterance = true
            state = .listening
            if settings.chime { NSSound(named: "Tink")?.play() }
        }
        guard isFinal else { return }
        chimedForCurrentUtterance = false
        if command.count >= 2 {
            handle(command)
        } else {
            // 名前だけ呼ばれた → 続けて命令を待つ
            acceptingCommand = true
            scheduleTimeout(6)
        }
    }

    private func scheduleTimeout(_ seconds: Double) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.state == .listening || self.state == .idle else { return }
            self.setIdle()
        }
    }

    private func setIdle() {
        timeoutTask?.cancel()
        acceptingCommand = false
        chimedForCurrentUtterance = false
        liveText = ""
        listener.muted = userPaused
        state = userPaused ? .paused : .idle
    }

    // MARK: 命令の処理

    /// 音声またはテキスト入力された命令を処理する
    func handle(_ text: String) {
        timeoutTask?.cancel()
        acceptingCommand = false
        liveText = ""
        listener.muted = true
        entries.append(ConversationEntry(role: "user", text: text))

        if let reply = localCommand(text) {
            entries.append(ConversationEntry(role: "system", text: reply.message))
            Task {
                await speakAndWait(reply.message)
                reply.keepListening ? openFollowup() : setIdle()
            }
            return
        }

        state = .thinking
        let backend: LLMBackend
        do {
            backend = try makeBackend(settings.backend, settings: settings)
        } catch {
            fail(error)
            return
        }
        let system = systemPrompt()
        let userText = text
        Task {
            entries.append(ConversationEntry(role: "assistant", text: ""))
            let idx = entries.count - 1
            var splitter = SentenceSplitter()
            var full = ""
            do {
                for try await chunk in backend.respond(history: history, user: userText, system: system) {
                    full += chunk
                    entries[idx].text = full
                    for sentence in splitter.push(chunk) {
                        speaker.say(sentence)
                        state = .speaking
                    }
                }
                speaker.say(splitter.flush())
                if full.isEmpty { entries.remove(at: idx) }
                history += [ChatMessage(role: "user", content: userText), ChatMessage(role: "assistant", content: full)]
                history = Array(history.suffix(20))
                state = .speaking
                await speaker.waitUntilIdle()
                openFollowup()
            } catch {
                if entries[idx].text.isEmpty { entries.remove(at: idx) }
                fail(error)
            }
        }
    }

    /// 応答後しばらくは呼びかけなしで話しかけられるようにする
    private func openFollowup() {
        guard !userPaused, settings.followupSeconds > 0 else { setIdle(); return }
        // 読み上げの残響を拾わないよう少し待ってからマイクを戻す
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            listener.muted = false
            acceptingCommand = true
            state = .listening
            scheduleTimeout(settings.followupSeconds)
        }
    }

    private func fail(_ error: Error) {
        Log.write("error: \(error)")
        let msg = error.localizedDescription
        entries.append(ConversationEntry(role: "system", text: "⚠️ \(msg)"))
        Task {
            await speakAndWait("申し訳ありません、エラーが発生しました。")
            setIdle()
        }
    }

    private func speakAndWait(_ text: String) async {
        speaker.voiceIdentifier = settings.voiceIdentifier
        speaker.rate = Float(settings.speechRate)
        listener.muted = true
        state = .speaking
        speaker.say(text)
        await speaker.waitUntilIdle()
    }

    /// AI に渡さずに処理する命令（スタンバイ・履歴リセット・AI 切り替え）
    private func localCommand(_ text: String) -> (message: String, keepListening: Bool)? {
        let t = text.lowercased()
        let short = text.count < 15
        if short, ["ありがとう", "おやすみ", "スタンバイ", "もういい", "以上", "終わり"].contains(where: { text.hasPrefix($0) }) {
            return ("承知しました。いつでもお呼びください。", false)
        }
        if ["会話", "履歴", "記憶"].contains(where: text.contains), ["リセット", "消して", "忘れて"].contains(where: text.contains) {
            history.removeAll()
            return ("会話の記憶をリセットしました。", true)
        }
        let switchVerbs = ["切り替え", "切りかえ", "変えて", "かえて", "にして", "戻して", "もどして", "チェンジ"]
        if switchVerbs.contains(where: t.contains) {
            for kind in BackendKind.allCases where kind.spokenAliases.contains(where: { t.contains($0.lowercased()) }) {
                if kind != .local, let account = kind.keychainAccount, (Keychain.get(account) ?? "").isEmpty {
                    return ("\(kind.shortLabel) の API キーが未設定です。設定画面から登録してください。", true)
                }
                settings.backend = kind
                return ("\(kind.shortLabel)に切り替えました。", true)
            }
        }
        return nil
    }

    private func systemPrompt() -> String {
        let title = settings.userTitle.isEmpty ? "ご主人様" : "\(settings.userTitle)様"
        return """
        あなたは「\(settings.agentName)」という名前の、\(title)の Mac 上で常駐する執事型 AI アシスタントです。
        - 返答は音声で読み上げられる。1〜3文の短い話し言葉で、要点から答える。
        - Markdown、箇条書き、絵文字、URL、コードは使わない。数字や記号も読み上げやすく書く。
        - 落ち着いた丁寧な口調で、ときどき控えめなユーモアを交えてよい。
        - Mac の操作（音量・アプリ起動・音楽など）や情報取得（時刻・天気・バッテリーなど）を頼まれたら、返答する前に必ず該当するツールを呼び出す。ツールを呼ばずに「設定しました」「開きました」などと言ってはいけない。
        - ツールで表現できない依頼は、推測せずにできないと伝える。
        - 音声認識の聞き間違いらしい不自然な文は、意図を推測して短く確認する。
        """
    }
}
