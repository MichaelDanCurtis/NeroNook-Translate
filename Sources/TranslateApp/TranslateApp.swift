import AppKit
import SwiftUI

/// The plugin application. Launched by the NeroNook host with `--neronook-plugin` (no visible window until the
/// host's `configure` action opens one), by `scripts/protocol-test.py` with `--protocol-test` over stdio, or
/// directly during development, when the session window opens at once.
@main
struct TranslateApp: App {
    @StateObject private var plugin = TranslatePlugin()

    var body: some Scene {
        WindowGroup(plugin.hosted || plugin.test ? "Translate Launcher" : "Translate") {
            LaunchView(plugin: plugin)
        }
        .defaultSize(width: 920, height: 640)
    }
}

/// Hosted: an empty launcher window that hides itself (the scene builder cannot branch, as in Voice).
/// Direct launch: the session window.
private struct LaunchView: View {
    @ObservedObject var plugin: TranslatePlugin
    var body: some View {
        if plugin.hosted || plugin.test {
            Color.clear.onAppear { NSApplication.shared.windows.first { $0.title == "Translate Launcher" }?.orderOut(nil) }
        } else {
            SessionView(session: plugin.session)
        }
    }
}
