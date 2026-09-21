import AppKit
import Foundation

/// AI が呼び出せる Mac 操作ツール。スキーマは共通の JSON Schema で定義し、各バックエンドで形式を変換する。
/// 音声の聞き間違いで危険な操作をしないよう、任意のシェルコマンドを実行するツールは用意していない。
struct ToolSpec {
    let name: String
    let description: String
    let properties: [String: [String: Any]]

    var parameters: [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys)]
    }
}

@MainActor
enum Tools {
    static let specs: [ToolSpec] = [
        ToolSpec(name: "get_datetime", description: "現在の日付と時刻を取得する", properties: [:]),
        ToolSpec(name: "open_app", description: "Mac のアプリを起動する。name はアプリ名（例: Safari, Music, Finder, カレンダー）",
                 properties: ["name": ["type": "string"]]),
        ToolSpec(name: "set_volume", description: "Mac の出力音量を 0〜100 で設定する",
                 properties: ["level": ["type": "integer", "minimum": 0, "maximum": 100]]),
        ToolSpec(name: "get_battery", description: "バッテリー残量と充電状態を取得する", properties: [:]),
        ToolSpec(name: "music_control",
                 description: "音楽（ミュージック.app）の再生操作。例:「音楽かけて」→play、「止めて」→pause、「次の曲」「スキップ」→next、「前の曲」→previous",
                 properties: ["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]]]),
        ToolSpec(name: "web_search", description: "ブラウザで Web 検索を開く（結果は読み上げられない）",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "get_weather", description: "指定した都市の現在の天気を取得する。city はローマ字推奨（例: Tokyo）",
                 properties: ["city": ["type": "string"]]),
        ToolSpec(name: "run_shortcut", description: "macOS のショートカット.app に登録されたショートカットを名前で実行する",
                 properties: ["name": ["type": "string"]]),
    ]

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// ツールを実行して (結果テキスト, エラーかどうか) を返す
    static func execute(name: String, arguments: Any?) async -> (String, Bool) {
        do {
            let args = try validate(name: name, arguments: arguments)
            return (try await run(name: name, args: args), false)
        } catch {
            return ("エラー: \(error.localizedDescription)", true)
        }
    }

    private static func validate(name: String, arguments: Any?) throws -> [String: Any] {
        guard let spec = specs.first(where: { $0.name == name }) else { throw ToolError(message: "unknown tool: \(name)") }
        var raw: [String: Any] = [:]
        if let s = arguments as? String {
            if !s.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
                    throw ToolError(message: "引数の JSON が不正です")
                }
                raw = obj
            }
        } else if let d = arguments as? [String: Any] {
            raw = d
        }
        var clean: [String: Any] = [:]
        for (key, prop) in spec.properties {
            guard let value = raw[key] else { throw ToolError(message: "missing argument: \(key)") }
            if prop["type"] as? String == "integer" {
                // 小さいローカルモデルは "50" のように文字列で渡してくることがある
                guard let n = (value as? NSNumber)?.doubleValue ?? Double("\(value)") else {
                    throw ToolError(message: "bad type for \(key)")
                }
                clean[key] = Int(n)
            } else {
                guard let s = value as? String else { throw ToolError(message: "bad type for \(key)") }
                if let allowed = prop["enum"] as? [String], !allowed.contains(s) {
                    throw ToolError(message: "\(key) must be one of \(allowed)")
                }
                clean[key] = s
            }
        }
        return clean
    }

    private static func run(name: String, args: [String: Any]) async throws -> String {
        switch name {
        case "get_datetime":
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "yyyy年M月d日(E) H時m分"
            return f.string(from: Date())
        case "open_app":
            let app = args["name"] as! String
            try await shell("/usr/bin/open", ["-a", app])
            return "\(app) を開きました"
        case "set_volume":
            let level = max(0, min(100, args["level"] as! Int))
            try appleScript("set volume output volume \(level)")
            return "音量を \(level) にしました"
        case "get_battery":
            return try await shell("/usr/bin/pmset", ["-g", "batt"])
        case "music_control":
            let cmd = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"][args["action"] as! String]!
            try appleScript("tell application \"Music\" to \(cmd)")
            return "Music: \(cmd)"
        case "web_search":
            let q = args["query"] as! String
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            NSWorkspace.shared.open(c.url!)
            return "ブラウザで「\(q)」を検索しました"
        case "get_weather":
            let city = args["city"] as! String
            var c = URLComponents(string: "https://wttr.in/")!
            c.path = "/" + city
            c.queryItems = [URLQueryItem(name: "format", value: "%l: %C 気温%t 湿度%h 風%w"), URLQueryItem(name: "lang", value: "ja")]
            var req = URLRequest(url: c.url!, timeoutInterval: 8)
            req.setValue("curl", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        case "run_shortcut":
            let n = args["name"] as! String
            let out = try await shell("/usr/bin/shortcuts", ["run", n], timeout: 60)
            return out.isEmpty ? "ショートカット「\(n)」を実行しました" : out
        default:
            throw ToolError(message: "unknown tool: \(name)")
        }
    }

    private static func appleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw ToolError(message: error[NSAppleScript.errorMessage] as? String ?? "AppleScript error") }
    }

    @discardableResult
    nonisolated private static func shell(_ path: String, _ args: [String], timeout: TimeInterval = 10) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    cont.resume(throwing: ToolError(message: out.isEmpty ? "exit \(proc.terminationStatus)" : out))
                }
            }
            do {
                try p.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
