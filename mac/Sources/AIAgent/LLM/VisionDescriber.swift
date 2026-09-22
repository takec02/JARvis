import Foundation

/// 会話に使っているモデルが画像を読めないとき、Mac の中の画像対応モデル（gemma3 など）に
/// 写真を見せて説明してもらう。写真は Mac の外に出ない
@MainActor
enum VisionDescriber {
    static var host = "http://localhost:11434"

    private static var cachedModel: String?
    private static var lookedUp = false

    /// 使う画像対応モデル。設定が空なら、Ollama に入っているモデルから自動で探す
    static func model() async -> String? {
        let configured = AppSettings.shared.visionModel.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        if lookedUp { return cachedModel }
        lookedUp = true
        guard let names = try? await installedModels() else { return nil }
        for name in names where await canSeeImages(name) {
            cachedModel = name
            break
        }
        return cachedModel
    }

    /// 設定を変えたら、探し直す
    static func reset() {
        cachedModel = nil
        lookedUp = false
    }

    /// 写真を見せて、日本語で説明してもらう
    static func describe(_ jpeg: Data) async -> String? {
        guard let model = await model() else { return nil }
        let prompt = """
        この写真に写っている主な物が何かを、日本語で2文以内で説明してください。
        人が写っている場合、人の外見や身元には触れず、手に持っている物や周りの物だけを説明してください。
        確かでないことは「はっきりしない」と書いてください。文字の読み取りは別で行うので、書かなくて構いません。
        """
        let body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "5m",
            "messages": [["role": "user", "content": prompt, "images": [jpeg.base64EncodedString()]]],
        ]
        do {
            var req = URLRequest(url: URL(string: "\(host)/api/chat")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 180
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = HTTP.json(String(decoding: data, as: UTF8.self)) ?? [:]
            let text = ((json["message"] as? [String: Any])?["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = json["error"] as? String {
                Log.write("vision describe error: \(error)")
                return nil
            }
            return text.isEmpty ? nil : text
        } catch {
            Log.write("vision describe failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Ollama への問い合わせ

    private static func installedModels() async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(host)/api/tags")!)
        let json = HTTP.json(String(decoding: data, as: UTF8.self)) ?? [:]
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["model"] as? String }
    }

    static func canSeeImages(_ model: String) async -> Bool {
        if let known = capabilityCache[model] { return known }
        var req = URLRequest(url: URL(string: "\(host)/api/show")!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        let caps = (try? await URLSession.shared.data(for: req))
            .flatMap { HTTP.json(String(decoding: $0.0, as: UTF8.self)) }?["capabilities"] as? [String] ?? []
        let ok = caps.contains("vision")
        capabilityCache[model] = ok
        return ok
    }

    private static var capabilityCache: [String: Bool] = [:]
}
