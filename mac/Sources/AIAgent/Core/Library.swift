import AppKit
import Foundation
import PDFKit
import Vision

/// 渡された資料（PDF・Word・PowerPoint・Excel・テキストなど）の中身を取り出して保存し、
/// 質問に関係する箇所だけを探して AI に渡す。資料は Mac の中だけに置く
@MainActor
@Observable
final class Library {
    static let shared = Library()

    struct Source: Codable, Identifiable, Hashable {
        var id = UUID()
        var name: String
        var path: String
        var addedAt = Date()
        var chunkCount = 0
        var note: String = ""
    }

    /// 資料を分けた1かたまり（どの資料のどこから来たかが分かるようにしておく）
    struct Chunk: Codable {
        let label: String   // 「3ページ目」「スライド2」など
        let text: String
    }

    private(set) var sources: [Source] = []
    private var chunks: [UUID: [Chunk]] = [:]

    static let folder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIAgent/資料")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL { Self.folder.appendingPathComponent("index.json") }

    init() {
        load()
    }

    // MARK: 保存と読み込み

    private func load() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Source].self, from: data) {
            sources = saved
        }
        for source in sources {
            let url = Self.folder.appendingPathComponent("\(source.id.uuidString).json")
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Chunk].self, from: data) {
                chunks[source.id] = saved
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func save(_ list: [Chunk], for id: UUID) {
        let url = Self.folder.appendingPathComponent("\(id.uuidString).json")
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: 追加・削除

    /// ファイルを資料として取り込む（同じファイルは入れ直しになる）
    @discardableResult
    func add(url: URL) async throws -> Source {
        let extracted = try await Self.extract(from: url)
        guard !extracted.isEmpty else {
            throw Tools.ToolError(message: "\(url.lastPathComponent) から文字を取り出せませんでした")
        }
        sources.removeAll { $0.path == url.path }
        var source = Source(name: url.lastPathComponent, path: url.path, chunkCount: extracted.count)
        source.chunkCount = extracted.count
        sources.append(source)
        chunks[source.id] = extracted
        save()
        save(extracted, for: source.id)
        Log.write("library add: \(url.lastPathComponent) → \(extracted.count)かたまり")
        return source
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        chunks[source.id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(source.id.uuidString).json"))
        save()
    }

    func removeAll() {
        for source in sources { remove(source) }
    }

    /// 元のファイルが変わっていたら取り込み直す
    func reload(_ source: Source) async throws {
        try await add(url: URL(fileURLWithPath: source.path))
    }

    // MARK: 探す

    struct Hit {
        let source: Source
        let chunk: Chunk
        let score: Double
    }

    /// 質問に関係するかたまりを、点数の高い順に返す
    func search(_ query: String, limit: Int = 6) -> [Hit] {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []
        for source in sources {
            for chunk in chunks[source.id] ?? [] {
                let score = Self.score(text: chunk.text, name: source.name, terms: terms)
                if score > 0 { hits.append(Hit(source: source, chunk: chunk, score: score)) }
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// 質問を言葉に分ける（日本語は単語の切れ目が無いので、macOS の分割器を使う）
    static func terms(in text: String) -> [String] {
        var result: Set<String> = []
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja_JP") as CFLocale)
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let range = Range(NSRange(location: r.location, length: r.length), in: text) else { continue }
            let word = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // 助詞など短すぎる語と、よくある言い回しは除く
            guard word.count >= 2, !stopWords.contains(word) else { continue }
            result.insert(word)
        }
        return Array(result)
    }

    private static let stopWords: Set<String> = [
        "教えて", "ください", "どこ", "なに", "なん", "する", "した", "して", "ある", "いる", "です", "ます",
        "この", "その", "あの", "これ", "それ", "あれ", "について", "ついて", "とは", "って", "から", "まで",
    ]

    /// 言葉がいくつ含まれるかで点数を付ける（資料名に含まれる語も少し足す）
    static func score(text: String, name: String, terms: [String]) -> Double {
        let lower = text.lowercased()
        let lowerName = name.lowercased()
        var score = 0.0
        for term in terms {
            let count = lower.components(separatedBy: term).count - 1
            if count > 0 { score += 1 + min(Double(count - 1), 3) * 0.2 }
            if lowerName.contains(term) { score += 0.5 }
        }
        // 短すぎるかたまりは情報が薄いので少し下げる
        if text.count < 120 { score *= 0.7 }
        return score
    }

    /// AI に渡す形にまとめる
    func context(for query: String, limit: Int = 6) -> String {
        let hits = search(query, limit: limit)
        guard !hits.isEmpty else { return "" }
        return hits.map { hit in
            "【\(hit.source.name) / \(hit.chunk.label)】\n\(hit.chunk.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: 中身を取り出す

    nonisolated static func extract(from url: URL) async throws -> [Chunk] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try await pdfChunks(url)
        case "txt", "md", "markdown", "csv", "tsv", "json", "log", "swift", "py", "js", "ts", "html", "htm", "xml", "yml", "yaml":
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .shiftJIS)) ?? ""
            return chunk(text: text, labelPrefix: "")
        case "rtf", "rtfd", "doc", "docx", "odt", "webarchive":
            return chunk(text: try attributedText(url), labelPrefix: "")
        case "pptx", "xlsx", "key", "numbers", "pages":
            return try officeChunks(url, ext: ext)
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "bmp":
            return try imageChunks(url)
        default:
            // 拡張子が分からないものは、文字として読めれば取り込む
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return chunk(text: text, labelPrefix: "")
            }
            throw Tools.ToolError(message: "この形式（\(ext)）は読み取れません")
        }
    }

    /// PDF はページごとに取り出す。文字が入っていないページは、画像として文字認識する
    nonisolated private static func pdfChunks(_ url: URL) async throws -> [Chunk] {
        guard let doc = PDFDocument(url: url) else { throw Tools.ToolError(message: "PDF を開けません") }
        var result: [Chunk] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count < 20 {
                // 画像だけのページ（スキャンした資料など）
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let image = NSImage(size: size, flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                    ctx.scaleBy(x: scale, y: scale)
                    page.draw(with: .mediaBox, to: ctx)
                    return true
                }
                if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let (lines, _) = try? Camera.analyze(cg) {
                    text = lines.joined(separator: "\n")
                }
            }
            result += chunk(text: text, labelPrefix: "\(i + 1)ページ")
        }
        return result
    }

    /// Word・RTF・HTML などは macOS の機能で本文にする
    nonisolated private static func attributedText(_ url: URL) throws -> String {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        return attributed.string
    }

    /// PowerPoint・Excel・Pages などは、中の XML から文字だけを取り出す
    nonisolated private static func officeChunks(_ url: URL, ext: String) throws -> [Chunk] {
        let inner: String
        switch ext {
        case "pptx": inner = "ppt/slides/slide*.xml"
        case "xlsx": inner = "xl/sharedStrings.xml xl/worksheets/sheet*.xml"
        default: inner = "*.xml"  // Pages・Keynote・Numbers（書き出し形式によっては読めない）
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + inner.split(separator: " ").map(String.init)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let xml = String(decoding: data, as: UTF8.self)
        guard !xml.isEmpty else { throw Tools.ToolError(message: "中身を取り出せませんでした") }
        let text = xml
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
        return chunk(text: text, labelPrefix: "")
    }

    /// 画像は文字認識でテキストにする
    nonisolated private static func imageChunks(_ url: URL) throws -> [Chunk] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Tools.ToolError(message: "画像を開けません")
        }
        let (lines, codes) = try Camera.analyze(image)
        var text = lines.joined(separator: "\n")
        if !codes.isEmpty { text += "\n" + codes.map { "\($0.kind): \($0.value)" }.joined(separator: "\n") }
        return chunk(text: text, labelPrefix: "")
    }

    /// 長い文章を、探しやすい大きさに分ける（前後を少し重ねて、文の途中で切れても拾えるようにする）
    nonisolated static func chunk(text: String, labelPrefix: String, size: Int = 900, overlap: Int = 150) -> [Chunk] {
        let cleaned = text.replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 20 else { return [] }
        if cleaned.count <= size {
            return [Chunk(label: labelPrefix.isEmpty ? "全体" : labelPrefix, text: cleaned)]
        }
        var result: [Chunk] = []
        var start = cleaned.startIndex
        var part = 1
        while start < cleaned.endIndex {
            let end = cleaned.index(start, offsetBy: size, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            let piece = String(cleaned[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.count > 20 {
                let label = labelPrefix.isEmpty ? "その\(part)" : "\(labelPrefix)・その\(part)"
                result.append(Chunk(label: label, text: piece))
                part += 1
            }
            if end == cleaned.endIndex { break }
            start = cleaned.index(end, offsetBy: -overlap, limitedBy: cleaned.startIndex) ?? end
        }
        return result
    }
}
