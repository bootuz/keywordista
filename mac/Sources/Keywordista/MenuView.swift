import AppKit
import SwiftUI

// The dropdown shown when the user clicks the menubar icon.
//
// Items, top to bottom:
//   • Status text + dot ("Running on :8080" etc.)
//   • Open Dashboard — opens http://127.0.0.1:8080/ in the default browser
//   • Launch at login (toggle)
//   • Quit Keywordista (sigterm child, NSApp.terminate)
//
// MenuBarExtra renders its body as a real macOS menu (not a popover) when
// menuBarExtraStyle is .menu (the default). That means we can't use
// arbitrary SwiftUI views — only Buttons, Toggles, Dividers, and Text.
struct MenuView: View {
    @EnvironmentObject var supervisor: ServiceSupervisor
    @EnvironmentObject var health: HealthMonitor
    @EnvironmentObject var loginItems: LoginItemManager

    var body: some View {
        Text(statusLine)

        Divider()

        Button("Open Dashboard") {
            if let url = URL(string: "http://127.0.0.1:\(supervisor.port)/") {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(!health.isHealthy)

        Divider()

        Toggle("Launch at login", isOn: Binding(
            get: { loginItems.isEnabled },
            set: { loginItems.setEnabled($0) }
        ))

        Divider()

        Button("Quit Keywordista") {
            // Drop the child cleanly before yanking the app — otherwise
            // launchd-or-our-own-parenting would leave an orphan listening
            // on :8080 even though the menubar icon is gone.
            Task {
                await supervisor.stop()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch supervisor.status {
        case .stopped:
            return "● Stopped"
        case .starting, .running:
            return health.isHealthy ? "● Running on :\(supervisor.port)" : "● Starting…"
        case .crashed(let reason):
            return "● Crashed: \(reason)"
        }
    }
}
