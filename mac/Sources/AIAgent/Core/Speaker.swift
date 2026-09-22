import AVFoundation

/// AVSpeechSynthesizer による読み上げ。文単位でキューに積み、全部話し終わるのを待てる。
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var voiceIdentifier = ""
    var gender: AgentGender = .male
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 性別を返さない声が多いため、既知の声は名前で判定する（並びは自然さの順）
    private static let maleNames = ["Otoya", "Hattori", "Reed", "Eddy", "Rocko", "Grandpa"]
    private static let femaleNames = ["Kyoko", "O-Ren", "Flo", "Sandy", "Shelley", "Grandma"]

    static func gender(of v: AVSpeechSynthesisVoice) -> AgentGender? {
        switch v.gender {
        case .male: return .male
        case .female: return .female
        default:
            if maleNames.contains(where: v.name.hasPrefix) { return .male }
            if femaleNames.contains(where: v.name.hasPrefix) { return .female }
            return nil
        }
    }

    static var japaneseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ja") }
    }

    /// 指定した性別の声を、品質の高い順・自然さの順に並べる
    static func voices(for gender: AgentGender) -> [AVSpeechSynthesisVoice] {
        let order = gender == .male ? maleNames : femaleNames
        func rank(_ v: AVSpeechSynthesisVoice) -> Int { order.firstIndex(where: v.name.hasPrefix) ?? order.count }
        return japaneseVoices
            .filter { Self.gender(of: $0) == gender }
            .sorted { ($0.quality.rawValue, -rank($0)) > ($1.quality.rawValue, -rank($1)) }
    }

    private var voice: AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { return v }
        return Self.voices(for: gender).first ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }

    func say(_ text: String) {
        let text = Self.clean(text)
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        pending += 1
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    var isIdle: Bool { pending == 0 }

    func waitUntilIdle() async {
        if pending == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finishedOne() {
        pending = max(0, pending - 1)
        if pending == 0 {
            let w = waiters
            waiters.removeAll()
            w.forEach { $0.resume() }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    /// Markdown 記号などを読み上げ向けに取り除く
    static func clean(_ text: String) -> String {
        var t = Markdown.strip(text)
        // 行頭の箇条書き記号を先に落とす
        t = t.replacingOccurrences(of: #"(?m)^[ \t]*[-–—•・][ \t]*"#, with: "", options: .regularExpression)
        // 「10:00」を「10時」、「14:30」を「14時30分」と読ませる（そのままだと「コロン」と読み上げる）
        t = t.replacingOccurrences(of: #"(?<!\d)([01]?\d|2[0-3]):00(?!\d)"#, with: "$1時", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)"#, with: "$1時$2分", options: .regularExpression)
        // 「10時 - 12時」を「10時から12時」と読ませる
        t = t.replacingOccurrences(of: #"(時|分)[ \t]*[-–—〜~][ \t]*(\d)"#, with: "$1から$2", options: .regularExpression)
        // 残ったコロンは、間として読ませる
        t = t.replacingOccurrences(of: #"[ \t]*[:：][ \t]*"#, with: "、", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// ストリーミングで届く文字列を、文の終わりごとに切り出す
struct SentenceSplitter {
    private var buffer = ""
    private static let enders: Set<Character> = ["。", "！", "？", "!", "?", "\n"]

    mutating func push(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        while let idx = buffer.firstIndex(where: { Self.enders.contains($0) }) {
            out.append(String(buffer[...idx]))
            buffer = String(buffer[buffer.index(after: idx)...])
        }
        return out
    }

    mutating func flush() -> String {
        defer { buffer = "" }
        return buffer
    }
}

/// AI が Markdown を混ぜて返してきたときに、読み上げと画面から記号を外す
enum Markdown {
    static func strip(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)  // リンク
        t = t.replacingOccurrences(of: #"```[a-zA-Z]*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)  // 見出し
        t = t.replacingOccurrences(of: #"[*_`~|>]"#, with: "", options: .regularExpression)  // 強調・引用・表の記号
        return t
    }
}
