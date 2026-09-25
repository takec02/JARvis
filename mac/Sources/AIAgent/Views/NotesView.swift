import AppKit
import SwiftUI

/// 議事録を読むための別ウィンドウ。要約・決定事項・宿題を上に、文字起こしを下に出す。
/// 要約がまだ無い議事録は、ここから作り直せる
struct NotesView: View {
    @Environment(AgentController.self) private var agent
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var body_: String = ""
    @State private var summarizing = false
    @State private var message: String?

    var body: some View {
        HSplitView {
            list
            detail
        }
        .frame(minWidth: 720, minHeight: 420)
        .task { reload() }
    }

    private var list: some View {
        List(files, id: \.self, selection: $selected) { url in
            VStack(alignment: .leading, spacing: 2) {
                Text(title(of: url)).lineLimit(1)
                Text(date(of: url)).font(.caption).foregroundStyle(.secondary)
            }
            .tag(url)
        }
        .frame(minWidth: 220, maxWidth: 280)
        .onChange(of: selected) { _, new in load(new) }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected.map(title(of:)) ?? "議事録")
                    .font(.headline)
                Spacer()
                if summarizing {
                    ProgressView().controlSize(.small)
                    Text("要約しています…").font(.caption).foregroundStyle(.secondary)
                } else if selected != nil, !hasSummary {
                    Button("要約を作る") { summarize() }
                }
                Button("Finder で開く") { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } }
                    .disabled(selected == nil)
                Button("更新") { reload() }
            }
            .padding(12)
            Divider()
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ScrollView {
                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    /// Markdown をそのまま読める形にする（見出しは太字で表示される）
    private var attributed: AttributedString {
        (try? AttributedString(markdown: body_, options: .init(interpretedSyntax: .full))) ?? AttributedString(body_)
    }

    private var hasSummary: Bool { body_.contains("## 要約") }

    private func title(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    private func date(of url: URL) -> String {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func reload() {
        let all = (try? FileManager.default.contentsOfDirectory(at: MeetingRecorder.folder,
                                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        files = all.filter { $0.pathExtension == "md" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        if selected == nil || !files.contains(selected!) { selected = files.first }
        load(selected)
    }

    private func load(_ url: URL?) {
        message = nil
        guard let url else {
            body_ = "議事録はまだありません。画面の ● ボタン、または「会議を記録して」で始められます。"
            return
        }
        body_ = (try? String(contentsOf: url, encoding: .utf8)) ?? "読み込めませんでした"
    }

    private func summarize() {
        guard let url = selected else { return }
        summarizing = true
        message = nil
        Task {
            do {
                try await agent.summarizeNotes(at: url)
                load(url)
            } catch {
                message = "要約を作れませんでした: \(error.localizedDescription)"
            }
            summarizing = false
        }
    }
}
