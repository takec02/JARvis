import AVFoundation

/// AVSpeechSynthesizer による読み上げ。文単位でキューに積み、全部話し終わるのを待てる。
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var voiceIdentifier = ""
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synth.delegate = self
    }

    static var japaneseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("ja") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    private var voice: AVSpeechSynthesisVoice? {
        if !voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { return v }
        return Self.japaneseVoices.first ?? AVSpeechSynthesisVoice(language: "ja-JP")
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
