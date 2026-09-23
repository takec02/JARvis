import AVFoundation
import Foundation
import Translation

/// 通訳の中身。話された言葉を、もう一方の言語に訳す。
/// 既定は macOS 内蔵の翻訳（端末内・速い）。設定で AI に切り替えると、文脈を踏まえた訳になる
@MainActor
enum Interpreter {
    /// 相手の言語として選べるもの（音声認識と翻訳の両方に対応しているもの）
    static let languages: [(id: String, label: String)] = [
        ("en-US", "英語（アメリカ）"), ("en-GB", "英語（イギリス）"),
        ("es-MX", "スペイン語（中南米）"), ("es-ES", "スペイン語（スペイン）"),
        ("zh-CN", "中国語（簡体）"), ("zh-TW", "中国語（繁体）"), ("ko-KR", "韓国語"),
        ("fr-FR", "フランス語"), ("de-DE", "ドイツ語"), ("it-IT", "イタリア語"),
        ("pt-BR", "ポルトガル語（ブラジル）"),
    ]

    static func label(for id: String) -> String {
        languages.first { $0.id == id }?.label ?? id
    }

    /// 「en-US」→「en」。翻訳は言語だけで指定する
    static func languageCode(_ identifier: String) -> String {
        String(identifier.split(separator: "-").first ?? "en")
    }

    // MARK: 翻訳

    /// text を from から to へ訳す。内蔵翻訳が使えないときは AI に回す
    static func translate(_ text: String, from: String, to: String, useAI: Bool) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !useAI, let built = await builtIn(trimmed, from: from, to: to) { return built }
        return await byAI(trimmed, from: from, to: to)
    }

    /// macOS 内蔵の翻訳（端末内）。言語データが入っていないときは nil を返す
    private static func builtIn(_ text: String, from: String, to: String) async -> String? {
        let source = Locale.Language(identifier: from)
        let target = Locale.Language(identifier: to)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            return try await session.translate(text).targetText
        } catch {
            Log.write("built-in translate failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// AI に訳してもらう（訳文だけを返させる）。
    /// ローカル AI のときは道具を渡さず、温度を下げた専用の呼び出しにする（訳がぶれないように）
    private static func byAI(_ text: String, from: String, to: String) async -> String? {
        let system = """
        あなたは通訳です。\(name(of: from))の文を\(name(of: to))に訳し、訳文だけを返してください。
        原文の意味・主語・時制・依頼や質問の形を変えないでください。
        説明・注釈・原文・引用符・記号は付けず、話し言葉として自然に訳してください。
        """
        let settings = AppSettings.shared
        if settings.backend == .local {
            return await byLocalModel(text, system: system, model: settings.ollamaModel)
        }
        guard let backend = try? makeBackend(settings.backend, settings: settings) else { return nil }
        var out = ""
        do {
            for try await chunk in backend.respond(history: [], user: text, system: system) { out += chunk }
        } catch {
            Log.write("AI translate failed: \(error.localizedDescription)")
            return nil
        }
        return clean(out)
    }

    private static func byLocalModel(_ text: String, system: String, model: String) async -> String? {
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "30m",
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
            "options": ["temperature": 0.2, "num_ctx": 4096],
        ]
        do {
            var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = HTTP.json(String(decoding: data, as: UTF8.self)) ?? [:]
            if let error = json["error"] as? String {
                Log.write("AI translate error: \(error)")
                return nil
            }
            return clean((json["message"] as? [String: Any])?["content"] as? String ?? "")
        } catch {
            Log.write("AI translate failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func clean(_ text: String) -> String? {
        var t = Markdown.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // 「訳: 」のような前置きや、前後の引用符を外す
        t = t.replacingOccurrences(of: #"^(訳文?|翻訳|Translation)\s*[:：]\s*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'“”"))
        return t.isEmpty ? nil : t
    }

    private static func name(of code: String) -> String {
        Locale(identifier: "ja_JP").localizedString(forLanguageCode: code) ?? code
    }

    /// 内蔵翻訳の言語データが入っているか（設定画面の表示用）
    static func builtInReady(_ foreign: String) async -> Bool {
        let ja = Locale.Language(identifier: "ja")
        let other = Locale.Language(identifier: languageCode(foreign))
        let a = await LanguageAvailability().status(from: ja, to: other)
        let b = await LanguageAvailability().status(from: other, to: ja)
        return a == .installed && b == .installed
    }

    // MARK: 話者の言語の判定

    /// ひらがな・漢字の割合。外国語をカタカナで書き起こした結果（「ハロー ハウ アー ユー」）と
    /// 本当の日本語を見分けるのに使う（カタカナだけの文は、外国語の空耳であることが多い）
    static func japaneseRatio(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let japanese = letters.filter { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        return Double(japanese.count) / Double(letters.count)
    }

    /// ラテン文字（英語・スペイン語など）の割合
    static func latinRatio(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let latin = letters.filter { (0x0041...0x024F).contains($0.value) }
        return Double(latin.count) / Double(letters.count)
    }

    /// 2つの認識結果から、実際に話された言語のほうを選ぶ
    static func pick(japanese: String?, foreign: String?) -> (text: String, isJapanese: Bool)? {
        let ja = japanese?.trimmingCharacters(in: .whitespaces) ?? ""
        let fo = foreign?.trimmingCharacters(in: .whitespaces) ?? ""
        if !ja.isEmpty, !fo.isEmpty {
            // ひらがな・漢字がそれなりに混じっていれば日本語。
            // カタカナばかりなら、相手の言語を日本語の認識器が空耳で拾ったものとみなす
            let isJapanese = japaneseRatio(ja) >= 0.2 || latinRatio(fo) < 0.3
            return isJapanese ? (ja, true) : (fo, false)
        }
        if !ja.isEmpty { return (ja, true) }
        if !fo.isEmpty { return (fo, false) }
        return nil
    }

    // MARK: 読み上げ

    /// その言語で読み上げる声（無ければ nil）
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = languageCode(language)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        // 同じ地域の声を優先し、次に品質の高いもの
        return voices.sorted {
            ($0.language == language ? 1 : 0, $0.quality.rawValue) > ($1.language == language ? 1 : 0, $1.quality.rawValue)
        }.first
    }
}
