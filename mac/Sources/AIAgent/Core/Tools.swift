import AppKit
import Foundation

/// AI が呼び出せる Mac 操作ツール。スキーマは共通の JSON Schema で定義し、各バックエンドで形式を変換する。
/// 音声の聞き間違いで危険な操作をしないよう、任意のシェルコマンドを実行するツールは用意していない。
struct ToolSpec {
    let name: String
    let description: String
    /// 引数の JSON Schema
    let parameters: [String: Any]
    /// 組み込みツールの引数定義（MCP ツールでは空）
    let properties: [String: [String: Any]]

    init(name: String, description: String, properties: [String: [String: Any]]) {
        self.name = name
        self.description = description
        self.properties = properties
        parameters = ["type": "object", "properties": properties, "required": Array(properties.keys)]
    }

    init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        properties = [:]
        parameters = schema
    }
}

@MainActor
enum Tools {
    /// AI に渡すツール（組み込み＋接続中の MCP サーバーのツール）
    /// - local: AI がローカル（Ollama）か。クラウドの AI にはローカル専用の MCP ツールを渡さない
    /// - tavily: Tavily の検索を含めるか（Claude は内蔵の Web 検索を使うので含めない）
    /// - query: 渡すと、外部サービスのツールを質問に関係するものだけに絞る（ローカル AI は道具が多いと使わなくなるため）
    static func specs(local: Bool, tavily: Bool = true, query: String? = nil) -> [ToolSpec] {
        builtin.filter { tavily || $0.name != "search_web" } + MCPManager.shared.toolSpecs(includeLocalOnly: local, query: query)
    }

    /// 動作確認用：すべてのツール
    static var allSpecs: [ToolSpec] { specs(local: true) }

    static let builtin: [ToolSpec] = [
        ToolSpec(name: "get_datetime", description: "現在の日付と時刻を取得する", properties: [:]),
        ToolSpec(name: "open_app", description: "Mac のアプリを起動する。name はアプリ名（例: Safari, Music, Finder, カレンダー）",
                 properties: ["name": ["type": "string"]]),
        ToolSpec(name: "set_volume", description: "Mac の出力音量を 0〜100 で設定する",
                 properties: ["level": ["type": "integer", "minimum": 0, "maximum": 100]]),
        ToolSpec(name: "get_battery", description: "バッテリー残量と充電状態を取得する", properties: [:]),
        ToolSpec(name: "music_control",
                 description: "音楽（ミュージック.app）の再生操作。例:「音楽かけて」→play、「止めて」→pause、「次の曲」「スキップ」→next、「前の曲」→previous",
                 properties: ["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]]]),
        ToolSpec(name: "search_web",
                 description: "インターネットで検索し、上位の結果（タイトル・URL・抜粋）と要約を返す。最新の情報、ニュース、店・イベント・人物など、知識だけでは確かでないことを調べるときに使う。必要なら続けて read_webpage で本文を読む",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "read_webpage", description: "指定した URL の Web ページの本文を読む（最大8000文字）",
                 properties: ["url": ["type": "string"]]),
        ToolSpec(name: "open_web_search", description: "ブラウザで検索結果のページを開く（ユーザーが画面で自分で見たいと言ったとき用。内容は読み上げられない）",
                 properties: ["query": ["type": "string"]]),
        ToolSpec(name: "get_weather",
                 description: "日本の天気予報（今日・明日の天気、降水確率、予想気温）を気象庁のデータで取得する。place は都道府県・地方・市区町村名（例: 東京、大阪府、札幌市、横浜）",
                 properties: ["place": ["type": "string"]]),
        ToolSpec(name: "open_weathernews", description: "ウェザーニュースの天気ページをブラウザで開く（ユーザーがウェザーニュースで見たいと言ったとき）。place は地名",
                 properties: ["place": ["type": "string"]]),
        ToolSpec(name: "calculate",
                 description: "計算をする。割引・税込み・合計・平均・割り算・単位換算など、数値の計算は暗算せず必ずこれを使う。expression は Python の数式（例: 12800*0.7*1.1、round(1234/7, 2)、sqrt(2)、sum([120, 340, 560])）",
                 properties: ["expression": ["type": "string"]]),
        ToolSpec(name: "run_shortcut", description: "macOS のショートカット.app に登録されたショートカットを名前で実行する",
                 properties: ["name": ["type": "string"]]),
    ]

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// ツールを実行して (結果テキスト, エラーかどうか) を返す
    static func execute(name: String, arguments: Any?) async -> (String, Bool) {
        if MCPManager.shared.handles(name) {
            return await MCPManager.shared.call(name, arguments: arguments, localAllowed: AppSettings.shared.backend == .local)
        }
        if CommandLine.arguments.contains("--llm-selftest") { print("  [tool] \(name) \(arguments ?? "")") }
        do {
            let args = try validate(name: name, arguments: arguments)
            return (try await run(name: name, args: args), false)
        } catch {
            return ("エラー: \(error.localizedDescription)", true)
        }
    }

    private static func validate(name: String, arguments: Any?) throws -> [String: Any] {
        guard let spec = builtin.first(where: { $0.name == name }) else { throw ToolError(message: "unknown tool: \(name)") }
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
        case "search_web":
            return try await WebTools.search(query: args["query"] as! String)
        case "read_webpage":
            return try await WebTools.read(urlString: args["url"] as! String)
        case "open_web_search":
            let q = args["query"] as! String
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            NSWorkspace.shared.open(c.url!)
            return "ブラウザで「\(q)」を検索しました"
        case "get_weather":
            return try await JMAWeather.forecast(place: args["place"] as! String)
        case "open_weathernews":
            // 規約で自動取得が禁止されているため、中身は読まずにブラウザで開くだけにする
            let place = args["place"] as! String
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: "ウェザーニュース \(place) 天気"), URLQueryItem(name: "btnI", value: "1")]
            NSWorkspace.shared.open(c.url!)
            return "ブラウザでウェザーニュースの\(place)の天気を開きました"
        case "calculate":
            return try await Calculator.evaluate(args["expression"] as! String)
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

/// 数式を Python で計算する。任意のコードは実行せず、構文木を調べて許可した計算だけを行う
/// （Web ページやメール経由で悪意ある式を渡されても、ファイル操作や通信はできない）
enum Calculator {
    private static let script = #"""
import ast, math, sys

src = sys.stdin.read()
FUNCS = {
    "abs": abs, "round": round, "min": min, "max": max, "sum": sum, "int": int, "float": float,
    "sqrt": math.sqrt, "floor": math.floor, "ceil": math.ceil, "log": math.log, "log10": math.log10,
    "log2": math.log2, "exp": math.exp, "sin": math.sin, "cos": math.cos, "tan": math.tan,
    "radians": math.radians, "degrees": math.degrees, "factorial": math.factorial, "gcd": math.gcd,
}
CONSTS = {"pi": math.pi, "e": math.e}
OPS = (ast.Add, ast.Sub, ast.Mult, ast.Div, ast.FloorDiv, ast.Mod, ast.Pow, ast.USub, ast.UAdd)

def check(node):
    if isinstance(node, ast.Expression): return check(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool): return
    if isinstance(node, ast.BinOp) and isinstance(node.op, OPS):
        check(node.left); check(node.right)
        if isinstance(node.op, ast.Pow):
            r = eval(compile(ast.Expression(node.right), "", "eval"), {"__builtins__": {}}, dict(FUNCS, **CONSTS))
            if abs(r) > 1000: raise ValueError("指数が大きすぎます")
        return
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, OPS): return check(node.operand)
    if isinstance(node, (ast.List, ast.Tuple)):
        for x in node.elts: check(x)
        return
    if isinstance(node, ast.Name) and node.id in CONSTS: return
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in FUNCS and not node.keywords:
        if node.func.id == "factorial" and isinstance(node.args[0], ast.Constant) and node.args[0].value > 1000:
            raise ValueError("大きすぎます")
        for a in node.args: check(a)
        return
    raise ValueError("使えない書き方です: " + type(node).__name__)

try:
    tree = ast.parse(src.replace("×", "*").replace("÷", "/").replace("^", "**").replace(",", ",").strip(), mode="eval")
    check(tree)
    v = eval(compile(tree, "", "eval"), {"__builtins__": {}}, dict(FUNCS, **CONSTS))
    if isinstance(v, float):
        v = int(v) if v.is_integer() and abs(v) < 1e15 else float("%.12g" % v)
    print(v)
except Exception as ex:
    print(str(ex))
    sys.exit(1)
"""#

    static func evaluate(_ expression: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw Tools.ToolError(message: "Python が見つかりません（xcode-select --install で入ります）")
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", "-c", script]  // -I: 環境変数やユーザーのパッケージを読まない
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = output
            p.terminationHandler = { proc in
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: "\(expression) = \(out)")
                } else {
                    cont.resume(throwing: Tools.ToolError(message: out.isEmpty ? "計算できませんでした" : out))
                }
            }
            do {
                try p.run()
                input.fileHandleForWriting.write(Data(expression.utf8))
                try? input.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
