import AppKit
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
    /// ログインに使う OAuth 設定の名前（mcp.json の "oauth" のキー）。Google 公式 MCP サーバーなど
    var oauth: String?
}

/// 設定ファイルの値のうち "keychain:<名前>" と書いたものは、キーチェーンから読んで使う（API キーを平文で書かないため）
enum SecretRef {
    static let prefix = "keychain:"

    static func resolve(_ value: String) -> String {
        // "keychain:名前" だけでなく、"Bearer keychain:名前" のように途中にあっても置き換える
        guard let r = value.range(of: prefix) else { return value }
        let account = String(value[r.upperBound...])
        return String(value[..<r.lowerBound]) + (Keychain.get(account) ?? "")
    }

    /// 秘密の値をキーチェーンに保存し、設定ファイルに書く参照文字列を返す
    static func store(_ value: String, account: String) -> String {
        Keychain.set(value, for: account)
        return prefix + account
    }
}

struct MCPConfigFile: Codable {
    var mcpServers: [String: MCPServerConfig]
    /// ブラウザでログインする MCP サーバー用の設定。複数のサーバーで1つのログインを共有できる
    var oauth: [String: OAuthConfig]?
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
    private(set) var oauthConfigs: [String: OAuthConfig] = [:]
    private var tokenBoxes: [String: TokenBox] = [:]
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
            let file = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            configs = file.mcpServers
            oauthConfigs = file.oauth ?? [:]
            configError = nil
        } catch {
            configs = [:]
            oauthConfigs = [:]
            configError = "設定ファイルを読めません: \(error.localizedDescription)"
        }
        serverNames = configs.keys.sorted()
        OAuthManager.shared.refreshLoginState(Array(oauthConfigs.keys))
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
                await self.refreshTokens()
                for name in self.serverNames where self.connections[name] == nil && self.configs[name]?.disabled != true {
                    await self.connect(name)
                }
            }
        }
    }

    /// ログイン済みのトークンを、期限が切れる前に更新して接続中のサーバーに渡す
    private func refreshTokens() async {
        for (name, box) in tokenBoxes {
            guard let oc = oauthConfigs[name] else { continue }
            if let t = try? await OAuthManager.shared.accessToken(name, config: oc) { box.token = t }
        }
    }

    /// 設定画面の「ログイン」。成功したら、そのログインを使うサーバーにつなぎ直す
    func login(_ oauthName: String) async throws {
        guard let oc = oauthConfigs[oauthName] else { return }
        try await OAuthManager.shared.login(oauthName, config: oc)
        for name in serverNames where configs[name]?.oauth == oauthName && configs[name]?.disabled != true {
            status[name] = .connecting
            await connect(name)
        }
    }

    func logout(_ oauthName: String) async {
        OAuthManager.shared.logout(oauthName)
        for name in serverNames where configs[name]?.oauth == oauthName {
            if let c = connections[name] { await c.client.disconnect() }
            connections[name] = nil
            status[name] = .unavailable(OAuthError.needsLogin.message)
        }
        rebuildToolIndex()
    }

    // MARK: Google の追加（設定画面から）

    struct GoogleService: Identifiable, Hashable {
        let id: String
        let label: String
        let url: String
        let scopes: [String]
    }

    /// Google 公式の Workspace MCP サーバー（開発者プレビュー。Google Workspace アカウントが必要）
    static let googleServices: [GoogleService] = [
        .init(id: "gmail", label: "Gmail", url: "https://gmailmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"]),
        .init(id: "calendar", label: "カレンダー", url: "https://calendarmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                       "https://www.googleapis.com/auth/calendar.events.freebusy",
                       "https://www.googleapis.com/auth/calendar.events.readonly"]),
        .init(id: "drive", label: "Drive", url: "https://drivemcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/drive.file"]),
        .init(id: "docs", label: "ドキュメント", url: "https://docsmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/documents.readonly"]),
        .init(id: "sheets", label: "スプレッドシート", url: "https://sheetsmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/spreadsheets.readonly"]),
        .init(id: "slides", label: "スライド", url: "https://slidesmcp.googleapis.com/mcp/v1",
              scopes: ["https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/presentations.readonly"]),
    ]

    private func updateConfigFile(_ change: (inout MCPConfigFile) -> Void) async throws {
        ensureConfigFile()
        let data = try Data(contentsOf: Self.configURL)
        var file = try JSONDecoder().decode(MCPConfigFile.self, from: data)
        change(&file)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(file).write(to: Self.configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
        await reload()
    }

    /// 会社の Google Workspace（公式 MCP サーバー）を追加する。ログインは設定画面の「ログイン」から
    func addGoogleWorkspace(clientId: String, clientSecret: String, services: Set<String>, localOnly: Bool) async throws {
        let chosen = Self.googleServices.filter { services.contains($0.id) }
        guard !chosen.isEmpty else { return }
        try await updateConfigFile { file in
            for svc in Self.googleServices { file.mcpServers["google-work-\(svc.id)"] = nil }
            for svc in chosen {
                file.mcpServers["google-work-\(svc.id)"] = MCPServerConfig(url: svc.url, localOnly: localOnly ? true : nil, oauth: "google-work")
            }
            var oauth = file.oauth ?? [:]
            var scopes: [String] = []
            for sc in chosen.flatMap(\.scopes) where !scopes.contains(sc) { scopes.append(sc) }
            oauth["google-work"] = OAuthConfig(clientId: clientId,
                                               clientSecret: clientSecret.isEmpty ? nil : SecretRef.store(clientSecret, account: "mcp.google-work.secret"),
                                               scopes: scopes)
            file.oauth = oauth
        }
    }

    /// 個人の Gmail など（有志の workspace-mcp を Mac の中で動かす）を追加する。ログインは初めて使うときにブラウザで
    func addGooglePersonal(clientId: String, clientSecret: String, email: String, localOnly: Bool) async throws {
        try await updateConfigFile { file in
            file.mcpServers["google-personal"] = MCPServerConfig(
                command: "uvx",
                args: ["workspace-mcp", "--single-user", "--tool-tier", "core", "--permissions",
                       "gmail:drafts", "calendar:full", "drive:readonly", "docs:readonly", "sheets:readonly", "slides:readonly"],
                env: ["GOOGLE_OAUTH_CLIENT_ID": clientId,
                      "GOOGLE_OAUTH_CLIENT_SECRET": SecretRef.store(clientSecret, account: "mcp.google-personal.secret"),
                      "USER_GOOGLE_EMAIL": email, "OAUTHLIB_INSECURE_TRANSPORT": "1"],
                localOnly: localOnly ? true : nil)
        }
    }

    // MARK: 業務サービスの追加（設定画面から）

    /// Backlog（ヌーラボ公式の MCP サーバー）
    func addBacklog(domain: String, apiKey: String) async throws {
        let host = domain.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await updateConfigFile { file in
            file.mcpServers["backlog"] = MCPServerConfig(
                command: "npx", args: ["-y", "backlog-mcp-server"],
                env: ["BACKLOG_DOMAIN": host,
                      "BACKLOG_API_KEY": SecretRef.store(apiKey, account: "mcp.backlog.apikey"),
                      "ENABLE_TOOLSETS": "space,project,issue,wiki,notifications,document"])
        }
    }

    /// kintone（サイボウズ公式の MCP サーバー）。API トークンか、ログイン名とパスワードのどちらか
    func addKintone(baseURL: String, apiToken: String, username: String, password: String) async throws {
        var env = ["KINTONE_BASE_URL": baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        if !apiToken.isEmpty { env["KINTONE_API_TOKEN"] = SecretRef.store(apiToken, account: "mcp.kintone.token") }
        if !username.isEmpty {
            env["KINTONE_USERNAME"] = username
            env["KINTONE_PASSWORD"] = SecretRef.store(password, account: "mcp.kintone.password")
        }
        try await updateConfigFile { file in
            file.mcpServers["kintone"] = MCPServerConfig(command: "npx", args: ["-y", "@kintone/mcp-server"], env: env)
        }
    }

    /// Salesforce（Salesforce が提供する Hosted MCP サーバー）。ログインはブラウザで
    func addSalesforce(serverURL: String, myDomain: String, clientId: String, clientSecret: String) async throws {
        let base = "https://" + myDomain.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try await updateConfigFile { file in
            file.mcpServers["salesforce"] = MCPServerConfig(url: serverURL, oauth: "salesforce")
            var oauth = file.oauth ?? [:]
            oauth["salesforce"] = OAuthConfig(
                clientId: clientId,
                clientSecret: clientSecret.isEmpty ? nil : SecretRef.store(clientSecret, account: "mcp.salesforce.secret"),
                scopes: ["mcp_api", "refresh_token"],
                authorizeUrl: base + "/services/oauth2/authorize",
                tokenUrl: base + "/services/oauth2/token")
            file.oauth = oauth
        }
    }

    /// URL だけで MCP サーバーを追加する。ログインが必要なら、標準の自動検出と自動登録を試す
    func addRemoteServer(name: String, url: String, needsLogin: Bool, clientId: String? = nil, clientSecret: String? = nil,
                         bearerToken: String? = nil, localOnly: Bool = false) async throws {
        guard let u = URL(string: url), u.scheme == "https" || u.host == "127.0.0.1" || u.host == "localhost" else {
            throw OAuthError(message: "https の URL を入れてください")
        }
        var oauthConfig: OAuthConfig?
        if needsLogin {
            var oc = try await OAuthDiscovery.discover(serverURL: u, redirectURI: OAuthConfig(clientId: "", scopes: []).redirectURI,
                                                       clientId: clientId, clientSecret: clientSecret)
            if let secret = oc.clientSecret { oc.clientSecret = SecretRef.store(secret, account: "mcp.\(name).secret") }
            oauthConfig = oc
        }
        try await updateConfigFile { file in
            var headers: [String: String]?
            if let bearerToken, !bearerToken.isEmpty {
                headers = ["Authorization": "Bearer " + SecretRef.store(bearerToken, account: "mcp.\(name).token")]
            }
            file.mcpServers[name] = MCPServerConfig(url: url, headers: headers, localOnly: localOnly ? true : nil,
                                                    oauth: oauthConfig == nil ? nil : name)
            if let oauthConfig {
                var oauth = file.oauth ?? [:]
                oauth[name] = oauthConfig
                file.oauth = oauth
            }
        }
    }

    // MARK: 書き込み前の確認

    /// 書き込み系のツールか（読むだけと明示されていれば不要。削除などの破壊的な操作や、名前が書き込みを表すものは確認する）
    private func needsConfirmation(_ tool: MCP.Tool) -> Bool {
        if tool.annotations.readOnlyHint == true { return false }
        if tool.annotations.destructiveHint == true { return true }
        let n = tool.name.lowercased()
        let verbs = ["add", "create", "update", "delete", "remove", "post", "send", "deploy", "move", "edit", "write",
                     "insert", "upload", "comment", "close", "merge", "manage", "modify", "set_", "set-", "put", "patch", "draft"]
        return verbs.contains { n.contains($0) }
    }

    /// 確認のために読み上げる説明（ツール名と、主な引数）
    private func describe(server: String, tool: MCP.Tool, args: [String: Value]) -> String {
        let label = server == "yuhitsu" ? "右筆" : server
        let action = tool.annotations.title ?? tool.title ?? tool.name
        let keys = ["summary", "title", "subject", "name", "content", "description", "record", "records", "body", "to", "app"]
        let details = keys.compactMap { k -> String? in
            guard let v = args[k] else { return nil }
            let text: String
            switch v {
            case .string(let s): text = s
            default: text = (try? String(data: JSONSerialization.data(withJSONObject: Self.toAny(v)), encoding: .utf8)) ?? ""
            }
            return text.isEmpty ? nil : String(text.prefix(60))
        }
        let detail = details.isEmpty ? "" : "内容は「\(details.prefix(2).joined(separator: "、"))」です。"
        return "\(label)で\(action)を実行します。\(detail)よろしいですか？"
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
                // ログインが必要なサーバーは、リクエストのたびに最新のアクセストークンを付ける
                var box: TokenBox?
                if let oauthName = config.oauth {
                    guard let oc = oauthConfigs[oauthName] else { throw MCPSetupError("OAuth 設定「\(oauthName)」が mcp.json にありません") }
                    let b = tokenBoxes[oauthName] ?? TokenBox()
                    tokenBoxes[oauthName] = b
                    b.token = try await OAuthManager.shared.accessToken(oauthName, config: oc)
                    box = b
                }
                transport = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
                    var r = request
                    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                    if let box { r.setValue("Bearer \(box.token)", forHTTPHeaderField: "Authorization") }
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
            var headers = (config.headers ?? [:]).mapValues(SecretRef.resolve)
            if let token = d.token { headers["Authorization"] = "Bearer \(token)" }
            return (url, headers)
        }
        guard let s = config.url, let url = URL(string: s) else {
            throw MCPSetupError("command か url を指定してください")
        }
        return (url, (config.headers ?? [:]).mapValues(SecretRef.resolve))
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
        env.forEach { environment[$0] = SecretRef.resolve($1) }
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
        if let e = error as? OAuthError { return e.message }
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
        if let spec = c.tools.first(where: { $0.name == tool }), needsConfirmation(spec) {
            let ok = await AgentController.shared.confirm(describe(server: server, tool: spec, args: args))
            if !ok {
                return ("ユーザーが実行を取りやめました。実行していないことを伝えてください", true)
            }
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
