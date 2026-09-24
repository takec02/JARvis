import Foundation

/// 「決まった人（または案件）の分がドライブに揃っているか」を確かめる。
/// 数え違いが起きないよう、AI に任せず、アプリが名簿とドライブを突き合わせる
@MainActor
enum Submissions {
    /// Google ドライブ・スプレッドシートの URL から ID を取り出す
    static func driveID(from text: String) -> String? {
        let patterns = [#"/folders/([A-Za-z0-9_-]{10,})"#, #"/d/([A-Za-z0-9_-]{10,})"#, #"[?&]id=([A-Za-z0-9_-]{10,})"#]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let matched = String(text[range])
                if let idRange = matched.range(of: #"[A-Za-z0-9_-]{10,}$"#, options: .regularExpression) {
                    return String(matched[idRange])
                }
            }
        }
        // すでに ID だけを渡された場合
        if text.range(of: #"^[A-Za-z0-9_-]{15,}$"#, options: .regularExpression) != nil { return text }
        return nil
    }

    /// 名簿（スプレッドシート）から名前の一覧を読む
    static func roster(sheet: String, range: String) async -> [String] {
        guard let id = driveID(from: sheet) else { return [] }
        let (text, isError) = await MCPManager.shared.call(
            "google-personal__read_sheet_values",
            arguments: ["spreadsheet_id": id, "range_name": range],
            localAllowed: true)
        guard !isError else {
            Log.write("roster read failed: \(text.prefix(120))")
            return []
        }
        // 1行1名の想定。見出しらしい行や空行は除く
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                // 「| A1 | 山田太郎 |」のような表形式でも、最後のセルを拾えるようにする
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let value = cells.count > 1 ? cells.last ?? line : line
                return value.isEmpty ? nil : value
            }
            .filter { !["名前", "氏名", "案件", "案件名", "name"].contains($0.lowercased()) }
    }

    /// フォルダ直下にあるフォルダ名の一覧
    static func folderNames(in folderID: String) async -> [String] {
        let query = "'\(folderID)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        let (text, isError) = await MCPManager.shared.call(
            "google-personal__search_drive_files",
            arguments: ["query": query, "page_size": 200],
            localAllowed: true)
        guard !isError else {
            Log.write("folder list failed: \(text.prefix(120))")
            return []
        }
        return names(in: text)
    }

    /// フォルダ直下にあるファイル名の一覧（フォルダではなくファイルで提出される場合）
    static func fileNames(in folderID: String) async -> [String] {
        let query = "'\(folderID)' in parents and trashed = false"
        let (text, isError) = await MCPManager.shared.call(
            "google-personal__search_drive_files",
            arguments: ["query": query, "page_size": 200],
            localAllowed: true)
        guard !isError else { return [] }
        return names(in: text)
    }

    /// MCP が返す一覧テキストから、名前だけを取り出す
    private static func names(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"^\s*-\s*(?:Name:\s*)?"?(.+?)"?\s*(?:\(|\||$)"#, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 比べるときの表記ゆれ（空白・記号・全角半角）を吸収する
    static func normalize(_ text: String) -> String {
        let half = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return half.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    struct Result {
        let submitted: [String]
        let missing: [String]
        let extra: [String]
    }

    /// 名簿とフォルダの中身を突き合わせる
    static func compare(roster: [String], found: [String]) -> Result {
        var remaining = found
        var submitted: [String] = []
        var missing: [String] = []
        for name in roster {
            let key = normalize(name)
            guard !key.isEmpty else { continue }
            if let index = remaining.firstIndex(where: { normalize($0).contains(key) || key.contains(normalize($0)) }) {
                submitted.append(name)
                remaining.remove(at: index)
            } else {
                missing.append(name)
            }
        }
        return Result(submitted: submitted, missing: missing, extra: remaining)
    }

    /// ツールから呼ばれる本体。フォルダの中身と名簿を突き合わせ、読み上げやすい文で返す
    static func check(folder: String, sheet: String, range: String) async throws -> String {
        guard let folderID = driveID(from: folder) else {
            throw Tools.ToolError(message: "フォルダの URL か ID を渡してください")
        }
        let names = await roster(sheet: sheet, range: range)
        guard !names.isEmpty else {
            throw Tools.ToolError(message: "名簿を読めませんでした（シートの URL と範囲を確かめてください）")
        }
        var found = await folderNames(in: folderID)
        if found.isEmpty { found = await fileNames(in: folderID) }
        let result = compare(roster: names, found: found)
        var lines = ["名簿 \(names.count)件のうち、提出済み \(result.submitted.count)件、未提出 \(result.missing.count)件。"]
        if result.missing.isEmpty {
            lines.append("全員そろっています。")
        } else {
            lines.append("未提出: " + result.missing.joined(separator: "、"))
        }
        if !result.extra.isEmpty {
            lines.append("名簿にない物: " + result.extra.prefix(10).joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}
