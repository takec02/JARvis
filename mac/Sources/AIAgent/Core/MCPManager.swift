import Foundation
import MCP
import Observation
import System

/// MCP サーバー1件分の設定。Claude Desktop などと同じ `mcpServers` 形式で書く。
///
///     { "mcpServers": {
///         "yuhitsu": { "discovery": "~/Library/Application Support/Yuhitsu/mcp.json" },
///         "files":   { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"] },
///         "remote":  { "url": "http://127.0.0.1:8080/mcp", "headers": { "Authorization": "Bearer ..." } },
///         "off":     { "command": "...", "disabled": true },
///         "private": { "command": "...", "localOnly": true } } }
///
/// `localOnly: true` のサーバーのツールは、AI がローカル（Ollama）のときだけ使える。
/// メールなど、Mac の外に出したくないデータを扱うサーバー向け（右筆は既定で true）。
struct MCPServerConfig: Codable, Equatable {
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var url: String?
    var headers: [String: String]?
    /// 接続情報（`{"url": ..., "token": ...}`）を書き出したファイル。起動中のアプリが公開する MCP サーバー向け
    var discovery: String?
    var disabled: Bool?
    var localOnly: Bool?
}

struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig]
}

enum MCPStatus: Equatable {
    case disabled, connecting, connected(tools: Int), unavailable(String)

    var label: String {
        switch self {
        case .disabled: "無効"
        case .connecting: "接続中…"
        case .connected(let n): "接続済み（ツール \(n) 個）"
        case .unavailable(let m): m
        }
    }
}

/// MCP サーバーに接続し、そのツールを AI から使えるようにする
@MainActor @Observable
final class MCPManager {
    static let shared = MCPManager()

    static let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIAgent")
        return dir.appendingPathComponent("mcp.json")
    }()

    private(set) var serverNames: [String] = []
    private(set) var status: [String: MCPStatus] = [:]
    private(set) var configError: String?

    private struct Connection {
        let client: Client
        let tools: [MCP.Tool]
        let process: Process?
    }

    private var configs: [String: MCPServerConfig] = [:]
    private var connections: [String: Connection] = [:]
    /// AI に見せるツール名 → (サーバー名, 元のツール名)
    private var toolIndex: [String: (server: String, tool: String)] = [:]
    private var retryTask: Task<Void, Never>?

    private init() {}

    // MARK: 設定ファイル

    private static let defaultConfig = MCPConfigFile(mcpServers: [
        // 右筆に同梱の中継コマンド（右筆のサンドボックス内の接続情報を読み、起動中の右筆につなぐ）
        "yuhitsu": MCPServerConfig(command: "/Applications/ゆうひつ.app/Contents/MacOS/yuhitsu-mcp", localOnly: true),
    ])

    /// ローカル AI 専用のサーバーか（右筆は、設定ファイルに書かれていなくても既定でローカル専用）
    func isLocalOnly(_ server: String) -> Bool {
        configs[server]?.localOnly ?? (server == "yuhitsu")
    }

    /// ローカル専用のサーバーに接続中か
    var hasLocalOnlyConnected: Bool {
        connections.keys.contains { isLocalOnly($0) }
    }

    /// 直近の応答でローカル専用のツールを使ったか（使ったやりとりは、クラウドの AI に渡す履歴から外す）
    private var localOnlyUsed = false

    func consumeLocalOnlyUsage() -> Bool {
        defer { localOnlyUsed = false }
        return localOnlyUsed
    }

    /// 設定ファイルがなければ、右筆を登録した初期設定を作る
    func ensureConfigFile() {
        let url = Self.configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(Self.defaultConfig) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// 設定を読み直し、すべてのサーバーに接続し直す
    func reload() async {
        ensureConfigFile()
        await disconnectAll()
        do {
            let data = try Data(contentsOf: Self.configURL)
            configs = try JSONDecoder().decode(MCPConfigFile.self, from: data).mcpServers
            configError = nil
        } catch {
            configs = [:]
            configError = "設定ファイルを読めません: \(error.localizedDescription)"
        }
        serverNames = configs.keys.sorted()
        for name in serverNames {
            status[name] = configs[name]?.disabled == true ? .disabled : .connecting
        }
        await withTaskGroup(of: Void.self) { group in
            for name in serverNames where configs[name]?.disabled != true {
                group.addTask { await self.connect(name) }
            }
        }
        startRetryLoop()
    }

    /// 未接続のサーバー（右筆がまだ起動していない等）に、定期的につなぎ直す
    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                for name in self.serverNames where self.connections[name] == nil && self.configs[name]?.disabled != true {
                    await self.connect(name)
                }
            }
        }
    }

    // MARK: 接続

    private func connect(_ name: String) async {
        guard let config = configs[name] else { return }
        do {
            let client = Client(name: "AIエージェント", version: "0.1.0")
            var process: Process?
            let transport: any Transport
            if let command = config.command {
                let (p, t) = try launchStdio(command: command, args: config.args ?? [], env: config.env ?? [:])
                process = p
                transport = t
            } else {
                let (url, headers) = try resolveHTTP(config)
                transport = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
                    var r = request
                    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                    return r
                })
            }
            _ = try await withTimeout(seconds: 20) { try await client.connect(transport: transport) }
            var tools: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let page = try await client.listTools(cursor: cursor)
                tools += page.tools
                cursor = page.nextCursor
            } while cursor != nil
            connections[name] = Connection(client: client, tools: tools, process: process)
            status[name] = .connected(tools: tools.count)
            Log.write("MCP connected: \(name) (\(tools.count) tools)")
        } catch {
            connections[name] = nil
            status[name] = .unavailable(Self.describe(error, name: name, config: config))
        }
        rebuildToolIndex()
    }

    /// アプリ終了時に、stdio で起動した MCP サーバーのプロセスを確実に止める
    func terminateProcesses() {
        for (_, c) in connections { c.process?.terminate() }
    }

    private func disconnectAll() async {
        for (_, c) in connections {
            await c.client.disconnect()
            c.process?.terminate()
        }
        connections.removeAll()
        rebuildToolIndex()
    }

    private func resolveHTTP(_ config: MCPServerConfig) throws -> (URL, [String: String]) {
        if let discovery = config.discovery {
            let path = (discovery as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: path) else {
                throw MCPSetupError("起動していないか、連携が OFF です")
            }
            struct Discovery: Decodable { let url: String; let token: String? }
            let d = try JSONDecoder().decode(Discovery.self, from: data)
            guard let url = URL(string: d.url) else { throw MCPSetupError("接続情報の URL が不正です") }
            var headers = config.headers ?? [:]
            if let token = d.token { headers["Authorization"] = "Bearer \(token)" }
            return (url, headers)
        }
        guard let s = config.url, let url = URL(string: s) else {
            throw MCPSetupError("command か url を指定してください")
        }
        return (url, config.headers ?? [:])
    }

    /// コマンドを起動し、標準入出力で MCP を話す
    private func launchStdio(command: String, args: [String], env: [String: String]) throws -> (Process, StdioTransport) {
        // 絶対パスのコマンドが無ければ、起動を試さずに「未インストール」とする（1分ごとの再接続で無駄に起動しないように）
        let path = (command as NSString).expandingTildeInPath
        if path.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: path) {
            throw MCPSetupError("インストールされていません")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [path] + args.map { ($0 as NSString).expandingTildeInPath }
        // GUI アプリは PATH が最小限なので、Homebrew などの場所を足す
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        env.forEach { environment[$0] = $1 }
        p.environment = environment
        let toServer = Pipe(), fromServer = Pipe()
        p.standardInput = toServer
        p.standardOutput = fromServer
        p.standardError = FileHandle.nullDevice
        try p.run()
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor)
        )
        return (p, transport)
    }

    private static func describe(_ error: Error, name: String, config: MCPServerConfig) -> String {
        if let e = error as? MCPSetupError { return e.message }
        if error is TimeoutError { return "応答がありません（タイムアウト）" }
        if error.localizedDescription.localizedCaseInsensitiveContains("connection closed") {
            return "接続を閉じられました（相手のアプリが起動していないか、連携が OFF の可能性があります）"
        }
        return "接続できません: \(error.localizedDescription)"
    }

    // MARK: ツール

    private func rebuildToolIndex() {
        toolIndex.removeAll()
        for name in serverNames {
            guard let c = connections[name] else { continue }
            for t in c.tools {
                toolIndex[Self.exposedName(server: name, tool: t.name)] = (name, t.name)
            }
        }
    }

    /// AI 各社の制限（英数字・_・- のみ、64文字まで）に合わせたツール名
    private static func exposedName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let cleaned = String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return String(cleaned.prefix(64))
    }

    /// AI に渡すツール定義（組み込みツールと同じ形式）。クラウドの AI にはローカル専用のサーバーのツールを見せない
    func toolSpecs(includeLocalOnly: Bool) -> [ToolSpec] {
        serverNames.flatMap { name -> [ToolSpec] in
            guard let c = connections[name], includeLocalOnly || !isLocalOnly(name) else { return [] }
            return c.tools.map { t in
                var schema = Self.toAny(t.inputSchema) as? [String: Any] ?? [:]
                schema.removeValue(forKey: "$schema")
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                let desc = "[\(name)] " + (t.description ?? t.title ?? t.name)
                return ToolSpec(name: Self.exposedName(server: name, tool: t.name), description: desc, schema: schema)
            }
        }
    }

    func handles(_ toolName: String) -> Bool { toolIndex[toolName] != nil }

    /// サーバーごとのツール名一覧（設定画面の表示用）
    func toolNames(of server: String) -> [String] {
        connections[server]?.tools.map(\.name) ?? []
    }

    /// MCP ツールを呼び出し、テキストにして返す
    func call(_ toolName: String, arguments: Any?, localAllowed: Bool) async -> (String, Bool) {
        guard let (server, tool) = toolIndex[toolName], let c = connections[server] else {
            return ("エラー: ツール \(toolName) は現在使えません", true)
        }
        if isLocalOnly(server) {
            // 念のため実行時にも確認する（ツール一覧から外していても、呼ばれたら拒否する）
            guard localAllowed else {
                return ("エラー: このツールはデータを Mac の外に出さないため、AI がローカルのときだけ使えます。AI をローカルに切り替えるよう伝えてください", true)
            }
            localOnlyUsed = true
        }
        var args: [String: Value] = [:]
        if let s = arguments as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            args = obj.mapValues(Self.toValue)
        } else if let d = arguments as? [String: Any] {
            args = d.mapValues(Self.toValue)
        }
        let finalArgs = args
        Log.write("MCP call: \(server) / \(tool)")  // 引数や結果（メール本文など）は記録しない
        do {
            let result = try await withTimeout(seconds: 60) { try await c.client.callTool(name: tool, arguments: finalArgs) }
            let text = result.content.map(Self.render).joined(separator: "\n")
            return (text.isEmpty ? "（結果なし）" : String(text.prefix(20000)), result.isError ?? false)
        } catch {
            // 接続が切れていたら、次回以降のためにつなぎ直しておく
            connections[server] = nil
            status[server] = .unavailable("接続が切れました")
            rebuildToolIndex()
            Task { await connect(server) }
            return ("エラー: \(error.localizedDescription)", true)
        }
    }

    private static func render(_ content: MCP.Tool.Content) -> String {
        switch content {
        case .text(let text, _, _): return text
        case .image(_, let mimeType, _, _): return "（画像: \(mimeType)）"
        case .resourceLink(let uri, let name, _, _, _, _): return "（リンク: \(name) \(uri)）"
        default: return "（テキスト以外の結果）"
        }
    }

    // MARK: Value ⇄ JSON

    static func toAny(_ v: Value) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(_, let d): return d.base64EncodedString()
        case .array(let a): return a.map(toAny)
        case .object(let o): return o.mapValues(toAny)
        }
    }

    static func toValue(_ any: Any) -> Value {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(toValue))
        case let o as [String: Any]: return .object(o.mapValues(toValue))
        default: return .null
        }
    }
}

struct MCPSetupError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
