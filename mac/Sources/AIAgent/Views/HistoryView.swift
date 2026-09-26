import AppKit
import SwiftUI

/// 会話の記録を日ごとに読み返す画面。言葉でも探せる
struct HistoryView: View {
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var body_: String = ""
    @State private var query = ""
    @State private var hits: [(date: String, line: String)] = []

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(files, id: \.self, selection: $selected) { url in
                    Text(url.deletingPathExtension().lastPathComponent).tag(url)
                }
                .onChange(of: selected) { _, new in load(new) }
            }
            .frame(minWidth: 160, maxWidth: 220)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    TextField("言葉で探す", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { hits = ChatLog.search(query) }
                    Button("探す") { hits = ChatLog.search(query) }
                    if !hits.isEmpty {
                        Button("戻す") {
                            hits = []
                            query = ""
                        }
                    }
                    Button("Finder で開く") {
                        NSWorkspace.shared.activateFileViewerSelecting([selected ?? ChatLog.folder])
                    }
                    Button("更新") { reload() }
                }
                .padding(12)
                Divider()
                ScrollView {
                    if hits.isEmpty {
                        Text(attributed)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("「\(query)」を含む発言 \(hits.count)件")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.date).font(.caption).foregroundStyle(.secondary)
                                    Text(hit.line).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .task { reload() }
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: body_, options: .init(interpretedSyntax: .full))) ?? AttributedString(body_)
    }

    private func reload() {
        files = ChatLog.files()
        if selected == nil || !files.contains(selected!) { selected = files.first }
        load(selected)
    }

    private func load(_ url: URL?) {
        guard let url else {
            body_ = "まだ会話の記録がありません。"
            return
        }
        body_ = (try? String(contentsOf: url, encoding: .utf8)) ?? "読み込めませんでした"
    }
}
