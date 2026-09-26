import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 資料の画面。ここに入れたファイルの中身について、会話で質問できるようになる
struct LibraryView: View {
    @State private var library = Library.shared
    @State private var busy: String?
    @State private var message: String?
    @State private var selected: Library.Source?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if library.sources.isEmpty {
                empty
            } else {
                list
            }
            if let message {
                Divider()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await addFiles([url]) }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("資料").font(.headline)
                Text(library.sources.isEmpty ? "ファイルをここにドラッグするか、「追加」で選びます"
                     : "\(library.sources.count)件。会話で「〇〇について資料にはどう書いてある？」と聞けます")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
            Button("追加") { pick() }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("PDF・Word・PowerPoint・Excel・テキスト・画像を入れられます")
                .foregroundStyle(.secondary)
            Text("入れた資料は Mac の中だけに置かれます（クラウドの AI を選んでいるときは、質問に関係する箇所だけが送られます）")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        List(library.sources, selection: $selected) { source in
            HStack {
                Image(systemName: icon(for: source.name)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                    Text("\(source.chunkCount)か所 ・ \(source.addedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("開く") { NSWorkspace.shared.open(URL(fileURLWithPath: source.path)) }
                    .buttonStyle(.borderless)
                Button("読み直す") {
                    Task { await reload(source) }
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { library.remove(source) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            .tag(source)
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "tiff": "photo"
        case "xlsx", "csv", "numbers": "tablecells"
        case "pptx", "key": "rectangle.on.rectangle"
        default: "doc.text"
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "資料にするファイル（またはフォルダ）を選んでください"
        panel.prompt = "追加"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addFiles(urls) }
    }

    private func addFiles(_ urls: [URL]) async {
        message = nil
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += contents.filter { !$0.hasDirectoryPath }
            } else {
                files.append(url)
            }
        }
        var failed: [String] = []
        for (i, url) in files.enumerated() {
            busy = "\(url.lastPathComponent) を読み込んでいます（\(i + 1)/\(files.count)）"
            do {
                try await library.add(url: url)
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        busy = nil
        if !failed.isEmpty { message = "読み込めなかったもの:\n" + failed.joined(separator: "\n") }
    }

    private func reload(_ source: Library.Source) async {
        busy = "\(source.name) を読み直しています"
        do {
            try await library.reload(source)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        busy = nil
    }
}
