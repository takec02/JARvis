import SwiftUI

/// 初回起動時の名前付け。名前が決まるまでエージェントは起動しない。
struct OnboardingView: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var name = "カンスケ"  // 初期値。自由に書き換えられる
    @State private var wakeWord = ""
    @State private var mode: DisplayMode = .window

    private let tint = AgentState.listening.tint
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedWake: String { wakeWord.trimmingCharacters(in: .whitespaces) }
    private var wakePreview: String { trimmedWake.isEmpty ? (trimmedName.isEmpty ? "カンスケ" : trimmedName) : trimmedWake }

    var body: some View {
        ZStack {
            HUDBackground(tint: tint)
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    CoreView(state: .listening, level: min(1, Double(trimmedName.count) / 8))
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AIエージェント")
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .tracking(3)
                        Text("はじめに、エージェントに名前をつけてください。")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                field(title: "NAME ─ 名前（必須）", placeholder: "エージェントの名前", text: $name, large: true,
                      notes: ["画面や会話の中で使われる、エージェントの名前です。自由に変更できます。"])


                field(title: "WAKE WORD ─ 呼びかけの言葉（任意）", placeholder: "空欄なら名前を使います（例: ヘイ カンスケ）", text: $wakeWord,
                      notes: ["この言葉が聞こえたときだけ反応します。それ以外の会話には反応しません。「\(wakePreview)、今何時？」",
                              "英字や漢字はカタカナで入れると確実です。短い言葉や日常語（例: アイ、テレビ）は誤反応しやすくなります。"])

                VStack(alignment: .leading, spacing: 8) {
                    label("DISPLAY ─ 表示方法")
                    Picker("", selection: $mode) {
                        ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    note("あとから設定で変更できます。")
                }

                HStack {
                    Spacer()
                    Button(action: finish) {
                        Text("起動する")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(trimmedName.isEmpty ? .white.opacity(0.3) : .black)
                            .padding(.horizontal, 22).padding(.vertical, 9)
                            .background(Capsule().fill(trimmedName.isEmpty ? Color.white.opacity(0.08) : tint))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                }
            }
            .padding(30)
        }
        .frame(width: 480)
        .preferredColorScheme(.dark)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(tint)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(title: String, placeholder: String, text: Binding<String>, large: Bool = false, notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.25)))
                .textFieldStyle(.plain)
                .font(.system(size: large ? 18 : 14))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.4), lineWidth: 0.8))
            ForEach(notes, id: \.self) { note($0) }
        }
    }

    private func finish() {
        guard !trimmedName.isEmpty else { return }
        let s = agent.settings
        s.agentName = trimmedName
        s.wakeWord = trimmedWake
        s.displayMode = mode
        dismissWindow(id: "onboarding")
        // 閉じるボタンを無効にしているため dismissWindow で閉じない場合があるので、直接閉じる
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("onboarding") == true }?.close()
        AppDelegate.applyDisplayMode(mode)
        if mode == .window { openWindow(id: "main") }
        agent.startIfReady()
    }
}
