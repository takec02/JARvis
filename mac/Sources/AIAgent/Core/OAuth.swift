import AppKit
import CryptoKit
import Foundation
import Network
import Observation

/// OAuth 2.0 の設定（mcp.json の "oauth" に書く）。Google 用の URL は省略できる。
///
///     "oauth": { "google-work": { "clientId": "...", "clientSecret": "...", "scopes": ["..."] } }
struct OAuthConfig: Codable, Equatable {
    var clientId: String
    var clientSecret: String?
    var scopes: [String]
    var authorizeUrl: String?
    var tokenUrl: String?
    /// ログイン後に戻ってくる先のポート。Google Cloud に http://127.0.0.1:<port>/oauth2callback を登録しておく
    var redirectPort: Int?
    /// MCP 標準のログインで、アクセス先のサーバーを示す値（RFC 8707 の resource）
    var resource: String?

    var authorizeURL: String { authorizeUrl ?? "https://accounts.google.com/o/oauth2/v2/auth" }
    var tokenURL: String { tokenUrl ?? "https://oauth2.googleapis.com/token" }
    var port: UInt16 { UInt16(redirectPort ?? 8723) }
    var redirectURI: String { "http://127.0.0.1:\(port)/oauth2callback" }
}

struct OAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static let needsLogin = OAuthError(message: "ログインが必要です（設定 → 連携 で「ログイン」）")
}

/// リクエストのたびに最新のアクセストークンを渡すための入れ物（別スレッドから読まれる）
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _token = ""
    var token: String {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }
}

/// ブラウザでのログイン（認可コード＋PKCE）と、トークンの保存・更新
@MainActor @Observable
final class OAuthManager {
    static let shared = OAuthManager()

    private struct Tokens: Codable {
        var access: String
        var refresh: String?
        var expiry: Date
    }

    /// ログイン済みの設定名（画面表示用）
    private(set) var loggedIn: Set<String> = []
    private(set) var loggingIn: String?

    private init() {}

    private func account(_ name: String) -> String { "oauth.\(name)" }

    private func load(_ name: String) -> Tokens? {
        guard let s = Keychain.get(account(name)), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: d)
    }

    private func save(_ t: Tokens?, _ name: String) {
        if let t, let d = try? JSONEncoder().encode(t) {
            Keychain.set(String(decoding: d, as: UTF8.self), for: account(name))
            loggedIn.insert(name)
        } else {
            Keychain.set("", for: account(name))
            loggedIn.remove(name)
        }
    }

    func refreshLoginState(_ names: [String]) {
        loggedIn = Set(names.filter { load($0)?.refresh != nil || (load($0)?.expiry ?? .distantPast) > Date() })
    }

    func logout(_ name: String) { save(nil, name) }

    /// 有効なアクセストークンを返す。期限が近ければ更新する。ログインしていなければ needsLogin
    func accessToken(_ name: String, config: OAuthConfig) async throws -> String {
        guard var t = load(name) else { throw OAuthError.needsLogin }
        if t.expiry > Date().addingTimeInterval(120) { return t.access }
        guard let refresh = t.refresh else { throw OAuthError.needsLogin }
        let json = try await tokenRequest(config, [
            "grant_type": "refresh_token", "refresh_token": refresh,
        ])
        guard let access = json["access_token"] as? String else {
            save(nil, name)  // 更新できない（取り消された・期限切れ）ならログインし直してもらう
            throw OAuthError.needsLogin
        }
        t.access = access
        t.expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if let r = json["refresh_token"] as? String { t.refresh = r }
        save(t, name)
        return access
    }

    /// ブラウザで同意画面を開き、戻ってきた認可コードをトークンに換える
    func login(_ name: String, config: OAuthConfig) async throws {
        loggingIn = name
        defer { loggingIn = nil }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(24)

        var c = URLComponents(string: config.authorizeURL)!
        c.queryItems = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),  // 更新用のトークンをもらう（Google 向け）
            .init(name: "prompt", value: "consent"),
        ]
        if config.scopes.isEmpty { c.queryItems?.removeAll { $0.name == "scope" } }
        if let r = config.resource { c.queryItems?.append(.init(name: "resource", value: r)) }
        let receiver = try LoopbackReceiver(port: config.port)
        NSWorkspace.shared.open(c.url!)
        let params = try await receiver.waitForCallback(timeout: 300)
        guard params["state"] == state else { throw OAuthError(message: "ログインの応答が一致しません（やり直してください）") }
        if let err = params["error"] { throw OAuthError(message: "ログインが拒否されました: \(err)") }
        guard let code = params["code"] else { throw OAuthError(message: "ログインの応答にコードがありません") }

        let json = try await tokenRequest(config, [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": config.redirectURI, "code_verifier": verifier,
        ])
        guard let access = json["access_token"] as? String else {
            throw OAuthError(message: "トークンを取得できません: \(json["error_description"] ?? json["error"] ?? "")")
        }
        save(Tokens(access: access, refresh: json["refresh_token"] as? String,
                    expiry: Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)), name)
    }

    private func tokenRequest(_ config: OAuthConfig, _ fields: [String: String]) async throws -> [String: Any] {
        var all = fields
        all["client_id"] = config.clientId
        if let r = config.resource { all["resource"] = r }
        if let s = config.clientSecret { all["client_secret"] = SecretRef.resolve(s) }
        var req = URLRequest(url: URL(string: config.tokenURL)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = all.map { URLQueryItem(name: $0, value: $1) }
        req.httpBody = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URLEncoded
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// ログイン後のリダイレクトを受け取る、この Mac の中だけの小さな HTTP サーバー（1回だけ受け付けて閉じる）
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params)
        } catch {
            throw OAuthError(message: "ポート \(port) を使えません（他のアプリが使用中の可能性）")
        }
    }

    func waitForCallback(timeout: Double) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { continuation = cont }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let e) = state { self?.finish(.failure(OAuthError(message: "ログインの受け取りに失敗しました: \(e)"))) }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(OAuthError(message: "ログインが時間内に完了しませんでした")))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[1].hasPrefix("/oauth2callback"),
                  let comps = URLComponents(string: "http://localhost" + parts[1]) else {
                conn.send(content: Self.response("Not Found", status: "404 Not Found"), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            let ok = params["code"] != nil
            let html = ok ? "ログインしました。このウィンドウを閉じて、AIエージェントに戻ってください。" : "ログインできませんでした。AIエージェントでやり直してください。"
            conn.send(content: Self.response(html), completion: .contentProcessed { _ in conn.cancel() })
            self?.finish(.success(params))
        }
    }

    private static func response(_ body: String, status: String = "200 OK") -> Data {
        let html = "<!doctype html><meta charset=utf-8><title>AIエージェント</title><body style=\"font-family:-apple-system;padding:40px\">\(body)</body>"
        let bytes = Data(html.utf8)
        return Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let cont: CheckedContinuation<[String: String], Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        guard let cont else { return }
        listener.cancel()
        cont.resume(with: result)
    }
}

/// MCP 標準のログイン設定の自動検出と、アプリの自動登録（RFC 9728 / RFC 8414 / RFC 7591）。
/// これに対応した MCP サーバーなら、URL を入れるだけでログインできる
enum OAuthDiscovery {
    /// clientId を渡したときは自動登録をせず、そのアプリでログインする（Slack・HubSpot など、事前にアプリを作る方式）
    static func discover(serverURL: URL, redirectURI: String, clientId: String? = nil, clientSecret: String? = nil) async throws -> OAuthConfig {
        guard let host = serverURL.host, let scheme = serverURL.scheme else { throw OAuthError(message: "URL が正しくありません") }
        let origin = "\(scheme)://\(host)\(serverURL.port.map { ":\($0)" } ?? "")"
        let path = serverURL.path == "/" ? "" : serverURL.path

        // 1) サーバーが案内する認可サーバーを調べる（なければサーバー自身）
        var authServer = origin
        var scopes: [String] = []
        for candidate in ["\(origin)/.well-known/oauth-protected-resource\(path)", "\(origin)/.well-known/oauth-protected-resource"] {
            if let meta = try? await getJSON(candidate) {
                if let first = (meta["authorization_servers"] as? [String])?.first { authServer = first }
                scopes = meta["scopes_supported"] as? [String] ?? []
                break
            }
        }

        // 2) 認可サーバーの設定（ログイン画面・トークン・アプリ登録の URL）
        let asURL = URL(string: authServer)!
        let asOrigin = "\(asURL.scheme ?? "https")://\(asURL.host ?? "")\(asURL.port.map { ":\($0)" } ?? "")"
        let asPath = asURL.path == "/" ? "" : asURL.path
        var meta: [String: Any]?
        for candidate in ["\(asOrigin)/.well-known/oauth-authorization-server\(asPath)", "\(asOrigin)/.well-known/oauth-authorization-server",
                          "\(asOrigin)/.well-known/openid-configuration\(asPath)"] {
            if let m = try? await getJSON(candidate) { meta = m; break }
        }
        guard let meta, let authorize = meta["authorization_endpoint"] as? String, let token = meta["token_endpoint"] as? String else {
            throw OAuthError(message: "このサーバーのログイン方式を見つけられませんでした")
        }
        if let clientId, !clientId.isEmpty {
            return OAuthConfig(clientId: clientId, clientSecret: (clientSecret?.isEmpty ?? true) ? nil : clientSecret, scopes: scopes,
                               authorizeUrl: authorize, tokenUrl: token, resource: serverURL.absoluteString)
        }
        guard let registration = meta["registration_endpoint"] as? String else {
            throw OAuthError(message: "このサーバーはアプリの自動登録に対応していません（サービス側でアプリを作り、クライアント ID を入れる必要があります）")
        }

        // 3) AIエージェントをアプリとして登録する
        var req = URLRequest(url: URL(string: registration)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "AIエージェント",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let reg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let clientId = reg["client_id"] as? String else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw OAuthError(message: "アプリの自動登録を断られました（HTTP \(code)）。このサーバーは決められたアプリからしか使えない可能性があります")
        }
        return OAuthConfig(clientId: clientId, clientSecret: reg["client_secret"] as? String, scopes: scopes,
                           authorizeUrl: authorize, tokenUrl: token, resource: serverURL.absoluteString)
    }

    private static func getJSON(_ url: String) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw OAuthError(message: "bad url") }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 10))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError(message: "not found") }
        return obj
    }
}
