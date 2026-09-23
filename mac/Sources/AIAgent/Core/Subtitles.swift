import AppKit
import SwiftUI

/// 会議や動画の音声を聞き取り、日本語に訳して画面の前面に字幕として出す。
/// ほかのアプリの上に重ねて表示し、クリックはすり抜ける（操作の邪魔をしない）
@MainActor
@Observable
final class Subtitles {
    static let shared = Subtitles()

    struct Line: Identifiable {
        let id = UUID()
        let original: String
        var translated: String
        let at = Date()
    }

    private(set) var running = false
    private(set) var lines: [Line] = []
    private(set) var status: String?

    private let transcriber = SystemAudioTranscriber()
    private var panel: NSPanel?

    /// 字幕の表示を始める。language は聞き取る言語（相手の言語）
    func start(language: String, translate: Bool = true) async throws {
        guard !running else { return }
        running = true
        lines.removeAll()
        status = "音声の取り込みを準備しています…"
        showPanel()
        do {
            try await transcriber.start(
                locale: Locale(identifier: language),
                assetStatus: { [weak self] message in self?.status = message },
                onFinal: { [weak self] text in self?.add(text, language: language, translate: translate) }
            )
            status = nil
        } catch {
            running = false
            hidePanel()
            throw error
        }
    }

    func stop() {
        guard running else { return }
        running = false
        status = nil
        Task { await transcriber.stop() }
        hidePanel()
    }

    private func add(_ text: String, language: String, translate: Bool) {
        var line = Line(original: text, translated: "")
        lines.append(line)
        if lines.count > 4 { lines.removeFirst(lines.count - 4) }
        guard translate else { return }
        let settings = AppSettings.shared
        Task {
            let translated = await Interpreter.translate(text, from: Interpreter.languageCode(language), to: "ja",
                                                         useAI: settings.interpreterUseAI) ?? ""
            line.translated = translated
            if let i = lines.firstIndex(where: { $0.id == line.id }) { lines[i].translated = translated }
        }
    }

    // MARK: 前面に出す小さな窓

    private func showPanel() {
        guard panel == nil else { return }
        let view = NSHostingView(rootView: SubtitleOverlay(subtitles: self))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true  // クリックはすり抜ける
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 450, y: frame.minY + 60))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 画面下に出る字幕（原文は小さく、訳は大きく）
private struct SubtitleOverlay: View {
    @Bindable var subtitles: Subtitles

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = subtitles.status {
                Text(status).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
            }
            ForEach(subtitles.lines.suffix(2)) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.original)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                    Text(line.translated.isEmpty ? "訳しています…" : line.translated)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(line.translated.isEmpty ? .white.opacity(0.4) : .white)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.72)))
        .padding(.horizontal, 8)
    }
}
