import Foundation

/// 会話を日ごとのファイルに残す。あとから「あの話いつだっけ」を探せるようにする。
/// ローカル専用のやりとり（メールなど）も Mac の中だけに残る
@MainActor
enum ChatLog {
    static let folder: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AIエージェント/会話ログ")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func file(for date: Date = Date()) -> URL {
        folder.appendingPathComponent("\(day.string(from: date)).md")
    }

    /// 1つの発言を書き足す
    static func append(role: String, name: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let who: String
        switch role {
        case "user": who = "あなた"
        case "assistant": who = name
        default: who = "メモ"
        }
        let line = "- **\(time.string(from: Date())) \(who)**: \(body.replacingOccurrences(of: "\n", with: "\n  "))\n"
        let url = file()
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "# 会話ログ \(day.string(from: Date()))\n\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// 新しい日から順に、記録のあるファイルを返す
    static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 言葉で探す。見つかった行を、新しい順に返す
    static func search(_ query: String, limit: Int = 30) -> [(date: String, line: String)] {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return [] }
        var result: [(String, String)] = []
        for url in files() {
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let date = url.deletingPathExtension().lastPathComponent
            for line in body.components(separatedBy: .newlines) where line.lowercased().contains(key) {
                result.append((date, line.trimmingCharacters(in: CharacterSet(charactersIn: "- "))))
                if result.count >= limit { return result }
            }
        }
        return result
    }
}
