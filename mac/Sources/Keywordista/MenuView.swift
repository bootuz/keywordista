import AppKit
import SwiftUI

// The dropdown shown when the user clicks the menubar icon.
//
// Always visible:
//   • Status text + dot ("Running on :8080" etc.)
//   • Open Dashboard
//   • Check for service updates  → triggers UpdateChecker.checkNow()
//   • Launch at login (toggle)
//   • Quit Keywordista
//
// Conditionally surfaced based on UpdateChecker.status:
//   • .available  → "● Update available (v0.2.0)" + "Apply Update"
//   • .applying   → "● Updating to v0.2.0… (stage)"
//   • .error      → "⚠ Update failed: <reason>" + "Retry"
//
// MenuBarExtra renders its body as a real macOS menu when style is .menu
// (the default), so the vocabulary here is limited to Buttons, Toggles,
// Dividers, and plain Text. No arbitrary SwiftUI — we work within those
// primitives.
struct MenuView: View {
    @EnvironmentObject var supervisor: ServiceSupervisor
    @EnvironmentObject var health: HealthMonitor
    @EnvironmentObject var loginItems: LoginItemManager
    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        Text(statusLine)

        Divider()

        Button("Open Dashboard") {
            if let url = URL(string: "http://127.0.0.1:\(supervisor.port)/") {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(!health.isHealthy)

        // Update-flow section. Renders nothing in the .idle and .checking
        // states so the menu stays quiet when there's nothing to do.
        updateSection

        Divider()

        Button("Check for service updates") {
            Task { await updates.checkNow() }
        }
        .disabled(isUpdateInProgress)

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

    // MARK: - Update flow rendering

    @ViewBuilder
    private var updateSection: some View {
        switch updates.status {
        case .idle, .checking:
            EmptyView()

        case .available(let version, _):
            Divider()
            Text("● Update available: v\(version)")
            Button("Apply Update") {
                Task { await updates.applyUpdate() }
            }

        case .applying(let version, let stage):
            Divider()
            Text("Updating to v\(version) — \(stage)…")
                .foregroundStyle(.secondary)

        case .error(let reason):
            Divider()
            Text("⚠ Update failed: \(reason)")
                .foregroundStyle(.red)
            Button("Retry") {
                Task { await updates.checkNow() }
            }
        }
    }

    // MARK: - Status line

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

    private var isUpdateInProgress: Bool {
        if case .applying = updates.status { return true }
        return false
    }
}
