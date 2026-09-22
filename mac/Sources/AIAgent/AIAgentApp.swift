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

    // 動作確認用: `AIAgent --mcp-selftest [ツール名 JSON引数]` で MCP の接続とツール呼び出しを表示して終了する
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
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
