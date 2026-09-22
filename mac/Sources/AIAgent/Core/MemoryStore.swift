import Foundation

/// 覚えておくこと1件（「山田さんは取引先」「返信は丁寧めに」など）
struct MemoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    /// ローカル AI のときだけ使う（クラウドの AI には渡さない）
    var localOnly = false
    var createdAt = Date()
}

/// 長く覚えておくことを Mac の中のファイルに保存する。
/// 毎回の指示文に入れて判断に使い、設定画面で見る・直す・消すことができる
@MainActor
@Observable
final class MemoryStore {
    static let shared = MemoryStore()

    private(set) var items: [MemoryItem] = []

    /// 指示文に入れる上限（多すぎると会話が遅くなるため）
    private let promptLimit = 40
    private let maxItems = 300

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIAgent")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memories.json")
    }()

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([MemoryItem].self, from: data) else { return }
        items = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    // MARK: 出し入れ

    /// 覚える。同じ内容があれば増やさない
    @discardableResult
    func remember(_ text: String, localOnly: Bool = false) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 300 else { return false }
        guard !items.contains(where: { $0.text == t }) else { return false }
        items.append(MemoryItem(text: t, localOnly: localOnly))
        if items.count > maxItems { items.removeFirst(items.count - maxItems) }
        save()
        return true
    }

    func update(_ item: MemoryItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        save()
    }

    func remove(_ item: MemoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    /// 言葉で探して消す。消した件数を返す
    func forget(matching query: String) -> [MemoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hit = items.filter { $0.text.localizedCaseInsensitiveContains(q) }
        guard !hit.isEmpty else { return [] }
        items.removeAll { m in hit.contains { $0.id == m.id } }
        save()
        return hit
    }

    func search(_ query: String, localAllowed: Bool) -> [MemoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let usable = items.filter { localAllowed || !$0.localOnly }
        guard !q.isEmpty else { return usable }
        return usable.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    /// 指示文に入れる文章（新しいものを優先する）
    func promptSection(localAllowed: Bool) -> String {
        let usable = items.filter { localAllowed || !$0.localOnly }
        guard !usable.isEmpty else { return "" }
        let lines = usable.suffix(promptLimit).map { "  ・\($0.text)" }.joined(separator: "\n")
        let omitted = usable.count > promptLimit ? "\n  （ほかにも覚えていることがある。必要なら recall ツールで探す）" : ""
        return "\n- 覚えていること（ユーザーから聞いた事実や好み。判断に使う）:\n\(lines)\(omitted)"
    }
}
