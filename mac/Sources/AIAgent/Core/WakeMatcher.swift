import Foundation

/// 認識結果の中からエージェントの名前（呼びかけ）を探す。
/// ひらがな/カタカナ、長音、ヴ/ブ、大文字小文字、空白や句読点の違いを吸収して照合する。
struct WakeMatcher {
    let words: [String]

    private static let vuMap: [Character: Character] = ["ァ": "バ", "ィ": "ビ", "ェ": "ベ", "ォ": "ボ"]
    /// 音声認識が英字で書きがちな呼びかけ語（「Heyジャービス」など）をカタカナに揃える
    private static let englishWords: [String: String] = [
        "hey": "ヘイ", "hi": "ハイ", "ok": "オーケー", "okay": "オーケー", "yo": "ヨー",
    ]

    /// 正規化した文字列と、各文字が元の文字列のどこから来たかの対応を返す
    static func normalizeWithMap(_ text: String) -> (chars: [Character], origin: [String.Index], originEnd: [String.Index]) {
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
                chars.append(c)
                origin.append(idx)
                originEnd.append(idx)
            }
            i += 1
        }
        return (chars, origin, originEnd)
    }

    static func normalize(_ s: String) -> String { String(normalizeWithMap(s).chars) }

    /// 名前が含まれていれば、名前を除いた残りの文（命令）を返す。含まれていなければ nil。
    func extractCommand(from text: String) -> String? {
        let (chars, origin, originEnd) = Self.normalizeWithMap(text)
        let normText = String(chars)
        for word in words.sorted(by: { Self.normalize($0).count > Self.normalize($1).count }) {
            let w = Self.normalize(word)
            guard !w.isEmpty, let r = normText.range(of: w) else { continue }
            let start = normText.distance(from: normText.startIndex, to: r.lowerBound)
            let end = start + w.count - 1
            let before = String(text[..<origin[start]])
            // 名前の直後に続く長音や句読点（正規化で消える文字）は命令に含めない
            let after = String(text[text.index(after: originEnd[end])...].drop { Self.normalize(String($0)).isEmpty })
            return (before + " " + after).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return nil
    }
}
