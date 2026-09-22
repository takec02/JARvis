import AppKit
import SwiftUI

@main
struct AIAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var agent = AgentController.shared

    var body: some Scene {
        // メニューバーのアイコン（どちらの表示方法でも常に表示）
        MenuBarExtra {
            HUDView(compact: true)
                .environment(agent)
                .frame(width: 360, height: 560)
        } label: {
            MenuBarLabel().environment(agent)
        }
        .menuBarExtraStyle(.window)

        Window("AIエージェント", id: "main") {
            HUDView()
                .environment(agent)
                .frame(minWidth: 400, minHeight: 620)
                .containerBackground(Color(red: 0.02, green: 0.03, blue: 0.05), for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 460, height: 720)
        .defaultLaunchBehavior(.suppressed)

        Window("AIエージェントへようこそ", id: "onboarding") {
            OnboardingView()
                .environment(agent)
                .windowDismissBehavior(.disabled)  // 名前をつけるまで閉じられない
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(agent)
        }
    }
}

/// メニューバーのアイコン。起動時に一度だけ、初回設定かメインウィンドウを開く。
private struct MenuBarLabel: View {
    @Environment(AgentController.self) private var agent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: agent.state.symbol)
            .task {
                AppDelegate.openWindow = { openWindow(id: $0) }
                // 動作確認用の起動では、画面・マイク・あいさつを始めない
                if AppDelegate.isSelfTest { return }
                let s = agent.settings
                if !s.isNamed {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "onboarding")
                    NSApp.activate()
                } else {
                    AppDelegate.applyDisplayMode(s.displayMode)
                    if s.displayMode == .window { openWindow(id: "main") }
                    agent.startIfReady()
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindow: ((String) -> Void)?

    static var isSelfTest: Bool {
        CommandLine.arguments.contains { $0.hasSuffix("-selftest") }
    }

    /// 2つ目を起動しようとしたら、すでに動いている方を前に出して、こちらは終了する（常に1つだけ）
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isSelfTest, let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me }) {
            other.activate()
            exit(0)
        }
    }

    // 動作確認用: `AIAgent --mcp-selftest [ツール名 JSON引数]` で MCP の接続とツール呼び出しを表示して終了する
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // 動作確認用: `AIAgent --meeting-selftest` で、別アプリの音声（say）が「相手」として文字起こしされるかを表示して終了する
        if args.contains("--meeting-selftest") {
            Task { @MainActor in
                let rec = MeetingRecorder()
                do {
                    try await rec.start()
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-v", "Kyoko", "本日の議題は新製品の発売日です。発売は十月一日に決定しました。山田さんは来週金曜までに見積もりを出してください。"]
                    try say.run()
                    say.waitUntilExit()
                    try await Task.sleep(for: .seconds(4))
                    let text = await rec.stop()
                    print("transcript:\n\(text)\nfile: \(rec.fileURL?.path ?? "-")")
                } catch {
                    print("error: \(error.localizedDescription)")
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --oauth-selftest <名前>` でログインを実行し、接続状況を表示して終了する
        if let j = args.firstIndex(of: "--oauth-selftest"), args.count > j + 1 {
            Task { @MainActor in
                let mcp = MCPManager.shared
                await mcp.reload()
                do { try await mcp.login(args[j + 1]); print("login ok") } catch { print("login error: \(error.localizedDescription)") }
                print("loggedIn: \(OAuthManager.shared.loggedIn)")
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --discover-selftest <URL>...` でログイン方式の自動検出だけを試す（アプリ登録はしない）
        if let k = args.firstIndex(of: "--discover-selftest") {
            Task { @MainActor in
                for u in args[(k + 1)...] {
                    do {
                        let oc = try await OAuthDiscovery.discover(serverURL: URL(string: u)!, redirectURI: "http://127.0.0.1:8723/oauth2callback", clientId: "dummy")
                        print("\(u)\n  authorize=\(oc.authorizeURL)\n  token=\(oc.tokenURL)\n  scopes=\(oc.scopes)")
                    } catch {
                        print("\(u)\n  error: \(error.localizedDescription)")
                    }
                }
                exit(0)
            }
            return
        }
        // 動作確認用: `AIAgent --llm-selftest "質問"` でローカル AI に1回質問し、ツールの呼び出しと答えを表示する
        if let q = args.firstIndex(of: "--llm-selftest"), args.count > q + 1 {
            Task { @MainActor in
                await MCPManager.shared.reload()
                print("tools: \(Tools.specs(local: true).count)")
                let backend = try! makeBackend(.local, settings: AppSettings.shared)
                var out = ""
                do {
                    for try await c in backend.respond(history: [], user: args[q + 1], system: AgentController.shared.debugSystemPrompt()) { out += c }
                } catch { out = "error: \(error)" }
                print("answer: \(out)")
                exit(0)
            }
            return
        }
        guard let i = args.firstIndex(of: "--mcp-selftest") else { return }
        Task { @MainActor in
            let mcp = MCPManager.shared
            await mcp.reload()
            for name in mcp.serverNames {
                print("[\(name)] \(mcp.status[name]?.label ?? "-") \(mcp.toolNames(of: name))")
            }
            if args.count > i + 2 {
                let (out, isError) = await Tools.execute(name: args[i + 1], arguments: args[i + 2])
                print("call \(args[i + 1]) → error=\(isError)\n\(out)")
            }
            print("specs: local=\(Tools.specs(local: true).count) cloud=\(Tools.specs(local: false).count)")
            if args.count > i + 2, mcp.handles(args[i + 1]) {
                let (out, isError) = await mcp.call(args[i + 1], arguments: args[i + 2], localAllowed: false)
                print("cloud call → error=\(isError) \(out.prefix(80))")
            }
            exit(0)
        }
    }

    /// メニューバーのみ: Dock に出さない / ウィンドウ＋Dock: 通常のアプリとして振る舞う
    @MainActor static func applyDisplayMode(_ mode: DisplayMode) {
        NSApp.setActivationPolicy(mode == .window ? .regular : .accessory)
        if mode == .window { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { MCPManager.shared.terminateProcesses() }
    }

    // 常駐アプリなのでウィンドウを閉じても終了しない
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Dock アイコンのクリックでメインウィンドウを開き直す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated {
                if AppSettings.shared.isNamed { Self.openWindow?("main") } else { Self.openWindow?("onboarding") }
            }
        }
        return true
    }
}
