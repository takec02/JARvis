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
        var t = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[*_#`>|~]"#, with: "", options: .regularExpression)
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
