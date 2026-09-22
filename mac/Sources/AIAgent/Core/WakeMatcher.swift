import Foundation

/// 認識結果の中からウェイクワードを探す。
/// ひらがな/カタカナ、長音、ヴ/ブ、大文字小文字、空白や句読点の違いを吸収し、
/// さらに漢字は読みに直して照合する（「のぶなが」が「信長」と書き起こされても反応する）。
struct WakeMatcher {
    let words: [String]
    /// 呼びかけの形（設定で選ぶ）
    var style: WakeStyle = .nameOnly
    /// 名前のあとに付ける呼びかけの言葉（「サスケ、応えて」）
    var callWords: [String] = []
    /// 名前の前に付ける呼びかけの言葉（「ヘイ、サスケ」）
    var prefixWords: [String] = []

    /// 表記でも読みでも照合できるように、両方の形をそろえておく
    static func forms(_ words: [String]) -> [String] {
        Set(words.flatMap { [normalize($0), reading($0)] }).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }
    private static let normalizedHonorifics = forms(["さん", "くん", "君", "ちゃん", "様", "さま", "殿"])

    private var usableCallWords: [String] { style == .after || style == .both ? Self.forms(callWords) : [] }
    private var usablePrefixWords: [String] { style == .before || style == .both ? Self.forms(prefixWords) : [] }

    /// ウェイクワード自体に呼びかけの言葉が入っているか（「ヘイ サスケ」と登録されている場合）
    static func hasCallWord(_ word: String, call: [String], prefix: [String]) -> Bool {
        let n = normalize(word)
        return forms(call + prefix).contains { n.count > $0.count && (n.hasPrefix($0) || n.hasSuffix($0)) }
    }

    /// 正規化した文字と、それぞれが元の文字列のどこから来たか
    typealias Mapped = (chars: [Character], origin: [String.Index], originEnd: [String.Index])

    private static let vuMap: [Character: Character] = ["ァ": "バ", "ィ": "ビ", "ェ": "ベ", "ォ": "ボ"]
    /// 音声認識が英字で書きがちな呼びかけ語（「Hey ◯◯」など）をカタカナに揃える
    private static let englishWords: [String: String] = [
        "hey": "ヘイ", "hi": "ハイ", "ok": "オーケー", "okay": "オーケー", "yo": "ヨー",
    ]

    /// カナの母音（ハ→a, ベ→e）。長音の揺れ（ハンベエ/ハンベー、リョウマ/リョーマ）を吸収するのに使う
    private static func vowel(of c: Character) -> Character? {
        guard let latin = String(c).applyingTransform(.latinToKatakana, reverse: true), let v = latin.last,
              "aeiou".contains(v) else { return nil }
        return v
    }

    /// 直前のカナの母音を伸ばしているだけの母音カナか（エ段+エ/イ、オ段+オ/ウ など）
    private static func isVowelExtension(_ c: Character, after prev: Character?) -> Bool {
        guard let prev, let pv = vowel(of: prev) else { return false }
        switch c {
        case "ア": return pv == "a"
        case "イ": return pv == "i" || pv == "e"
        case "ウ": return pv == "u" || pv == "o"
        case "エ": return pv == "e"
        case "オ": return pv == "o"
        default: return false
        }
    }

    static func normalizeWithMap(_ text: String) -> Mapped {
        let indices = Array(text.indices)
        var chars: [Character] = []
        var origin: [String.Index] = []
        var originEnd: [String.Index] = []
        var i = 0
        while i < indices.count {
            let idx = indices[i]
            // 英字の単語はまとめて読み、既知の呼びかけ語ならカタカナとして扱う
            if text[idx].isASCII, text[idx].isLetter {
                var j = i
                while j < indices.count, text[indices[j]].isASCII, text[indices[j]].isLetter { j += 1 }
                let word = String(text[idx..<(j < indices.count ? indices[j] : text.endIndex)]).lowercased()
                if let kana = englishWords[word] {
                    for c in kana where c != "ー" {
                        chars.append(c)
                        origin.append(idx)
                        originEnd.append(indices[j - 1])
                    }
                    i = j
                    continue
                }
            }
            var s = String(text[idx]).applyingTransform(.hiraganaToKatakana, reverse: false) ?? String(text[idx])
            s = s.lowercased()
            if s == "ヴ" {
                // ヴァ/ヴィ/ヴェ/ヴォ → バ/ビ/ベ/ボ、単独のヴ → ブ
                let next = i + 1 < indices.count ? (String(text[indices[i + 1]]).applyingTransform(.hiraganaToKatakana, reverse: false) ?? "") : ""
                if let n = next.first, let mapped = vuMap[n] {
                    chars.append(mapped)
                    origin.append(idx)
                    originEnd.append(indices[i + 1])
                    i += 2
                    continue
                }
                s = "ブ"
            }
            for c in s where !(c.isWhitespace || c.isPunctuation || c.isSymbol || c == "ー" || c == "・") {
                if isVowelExtension(c, after: chars.last) { continue }
                chars.append(c)
                origin.append(idx)
                originEnd.append(idx)
            }
            i += 1
        }
        return (chars, origin, originEnd)
    }

    /// 漢字まじりの文を単語ごとに読み（カタカナ）へ直し、正規化する
    static func readingWithMap(_ text: String) -> Mapped {
        var result: Mapped = ([], [], [])
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let range = Range(NSRange(location: r.location, length: r.length), in: text), !range.isEmpty else { continue }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            let kana = latin?.applyingTransform(.latinToKatakana, reverse: false) ?? String(text[range])
            let last = text.index(before: range.upperBound)
            for c in normalizeWithMap(kana).chars {
                result.chars.append(c)
                result.origin.append(range.lowerBound)
                result.originEnd.append(last)
            }
        }
        return result
    }

    static func normalize(_ s: String) -> String { String(normalizeWithMap(s).chars) }
    static func reading(_ s: String) -> String { String(readingWithMap(s).chars) }

    /// ウェイクワードが含まれていれば、それを除いた残りの文（命令）を返す。含まれていなければ nil。
    func extractCommand(from text: String) -> String? {
        let sorted = words.sorted { Self.normalize($0).count > Self.normalize($1).count }
        // まず表記どおりに探し、見つからなければ読みで探す
        let direct = Self.normalizeWithMap(text)
        for word in sorted {
            if let cmd = Self.command(in: text, mapped: direct, word: Self.normalize(word), needsCall: needsCall(word), call: usableCallWords, prefix: usablePrefixWords) { return cmd }
        }
        let byReading = Self.readingWithMap(text)
        for word in sorted {
            if let cmd = Self.command(in: text, mapped: byReading, word: Self.reading(word), needsCall: needsCall(word), call: usableCallWords, prefix: usablePrefixWords) { return cmd }
        }
        return nil
    }

    private func needsCall(_ word: String) -> Bool {
        style != .nameOnly && !Self.hasCallWord(word, call: callWords, prefix: prefixWords)
    }

    private static func command(in text: String, mapped: Mapped, word: String, needsCall: Bool,
                                call normalizedCallWords: [String], prefix normalizedPrefixes: [String]) -> String? {
        let normText = String(mapped.chars)
        guard !word.isEmpty else { return nil }
        // 名前が何度か出てくることもあるので、呼びかけの言葉が付いている箇所を順に探す
        var searchFrom = normText.startIndex
        var found: (start: Int, prefixLength: Int, callLength: Int)?
        while found == nil, let r = normText.range(of: word, range: searchFrom..<normText.endIndex) {
            let start = normText.distance(from: normText.startIndex, to: r.lowerBound)
            if !needsCall {
                found = (start, 0, 0)
            } else if let p = normalizedPrefixes.first(where: { normText[..<r.lowerBound].hasSuffix($0) }) {
                found = (start, p.count, 0)  // 「ヘイ、サスケ」
            } else {
                // 「サスケ、応えて」。敬称（サスケさん、応えて）は間にあってもよい
                var tail = normText[r.upperBound...]
                var consumed = 0
                if let h = normalizedHonorifics.first(where: { tail.hasPrefix($0) }) {
                    tail = tail.dropFirst(h.count)
                    consumed += h.count
                }
                if let c = normalizedCallWords.first(where: { tail.hasPrefix($0) }) {
                    found = (start, 0, consumed + c.count)
                }
            }
            searchFrom = normText.index(after: r.lowerBound)
        }
        guard let (start, prefixLength, callLength) = found else { return nil }
        let end = start + word.count - 1
        let before = String(text[..<mapped.origin[start - prefixLength]])
        var rest = Substring(text[text.index(after: mapped.originEnd[end + callLength])...])
        if callLength == 0 {
            // 名前のすぐ後に助詞が続くなら、呼びかけではなく話題として名前を使っている
            //（「サスケのことを教えて」「サスケって何ができるの？」）。名前を消さずに全文を渡す
            let particles = ["の", "は", "が", "を", "に", "と", "も", "って", "で", "へ", "や", "から", "より", "みたい", "らしい"]
            if particles.contains(where: { rest.hasPrefix($0) }) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // 「サスケさん、…」の敬称は、呼びかけの一部として一緒に取り除く
            for honorific in ["さん", "くん", "君", "ちゃん", "様", "さま", "殿"] where rest.hasPrefix(honorific) {
                rest = rest.dropFirst(honorific.count)
                break
            }
        }
        // 呼びかけの直後に続く長音や句読点（正規化で消える文字）は命令に含めない
        let after = String(rest.drop { normalize(String($0)).isEmpty })
        return (before + " " + after).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
