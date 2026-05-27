import AppKit
import SwiftUI

/// Multi-instance replacement for the pre-M3 MenuView. Renders one
/// submenu per Instance in InstanceStore — local + any number of
/// remote PaaS deployments — plus the deploy-flow entry points and
/// the launch-at-login / quit globals.
///
/// **MenuBarExtra restrictions**: this view body must use only the
/// menu-compatible SwiftUI vocabulary (Button, Toggle, Divider, Text,
/// `Menu { ... }`). Arbitrary view hierarchies don't render correctly
/// in the menubar dropdown.
///
/// **Submenu layout per instance** (matches plan §3.3):
///   • Local instance: Open dashboard, Restart, Stop
///   • Remote instance: Open dashboard, View logs (M5), Update (M5),
///     Backup (M5), Disconnect (M3.12), Delete (M3.12)
struct MenuView_v2: View {
    @ObservedObject var instanceStore: InstanceStore
    @ObservedObject var health: HealthCoordinator
    @ObservedObject var supervisor: ServiceSupervisor
    @ObservedObject var loginItems: LoginItemManager
    @ObservedObject var updates: UpdateChecker

    /// Opens the deploy-flow window. Injected from KeywordistaApp
    /// (M3.13) which owns the WindowGroup.
    let onDeploy: () -> Void

    /// Opens the "Add existing deployment" sheet. M3.10 implements
    /// the sheet; this callback fires it.
    let onAddExisting: () -> Void

    /// Disconnect → remove from menubar only (M3.12). The owner
    /// (KeywordistaApp wiring) shows a confirm dialog first.
    let onDisconnect: (Instance) -> Void

    /// Delete → call provider.destroy then disconnect (M3.12). Owner
    /// shows a strong confirm because it's irreversible.
    let onDelete: (Instance) -> Void

    var body: some View {
        // Per-instance submenus (or empty state).
        if instanceStore.instances.isEmpty {
            Text("No deployments yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(instanceStore.instances) { instance in
                instanceMenu(for: instance)
            }
        }

        Divider()

        Button("Deploy to a server…", action: onDeploy)
        Button("Add existing deployment…", action: onAddExisting)

        Divider()

        // Service-update flow (the .app/service-binary updater) —
        // unchanged from pre-M3. Lives at the bottom of the menu
        // because it's an infrequent operation.
        updateSection

        Toggle("Launch at login", isOn: Binding(
            get: { loginItems.isEnabled },
            set: { loginItems.setEnabled($0) }
        ))

        Divider()

        Button("Quit Keywordista") {
            // Stop the spawned Vapor child cleanly, then exit(0) —
            // **bypassing** NSApp.terminate(nil). Empirically the
            // AppKit termination dance hangs when reached from a
            // Task context after `await`: AppKit's `.terminateLater`
            // wait state (entered by `applicationShouldTerminate`)
            // doesn't drain subsequent Task continuations on the
            // main actor, so the delegate's
            // `NSApp.reply(toApplicationShouldTerminate:)` never
            // fires and Quit hangs forever. This is the same
            // workaround `AppShutdownDelegate`'s SIGTERM signal
            // handler uses — see its comment for the diagnosis.
            // Since `supervisor.stop()` runs here we don't need the
            // delegate's stop() invocation; `exit(0)` is safe.
            Task {
                await supervisor.stop()
                exit(0)
            }
        }
        .keyboardShortcut("q")
    }

    // MARK: - Per-instance submenu

    @ViewBuilder
    private func instanceMenu(for instance: Instance) -> some View {
        let monitor = health.monitor(for: instance.id)
        let dot = statusDot(for: monitor)

        Menu("\(dot) \(instance.displayName)") {
            Button("Open dashboard") {
                NSWorkspace.shared.open(instance.baseURL)
            }
            .disabled(monitor?.isHealthy != true)

            switch instance.kind {
            case .local:
                Divider()
                Button("Restart backend") {
                    Task {
                        await supervisor.stop()
                        await supervisor.start()
                    }
                }
                Button("Stop") {
                    Task { await supervisor.stop() }
                }
                .disabled(supervisor.status != .running)

            case .remote(let remote):
                Divider()
                // M5 stubs — disabled but visible so the user sees
                // what's coming. Removed entirely would be more
                // honest; greyed-out gives a roadmap signal.
                Button("View deploy logs…") {}.disabled(true)
                Button("Update to latest →") {}.disabled(true)
                Button("Download backup…") {}.disabled(true)

                Divider()
                Button("Disconnect (keep server running)") {
                    onDisconnect(instance)
                }
                // Imported instances (M3.10) don't have a provider API
                // token in Keychain, so Delete is unavailable for them.
                // Disconnect still works — it's the right action there.
                if remote.providerAccountId != nil {
                    Button("Delete (destroy on provider)", role: .destructive) {
                        onDelete(instance)
                    }
                }
            }
        }
    }

    // MARK: - Status dot

    /// Three-color dot prefix matching the menubar icon's rollup:
    /// green = healthy, yellow = stale/unknown, red = unhealthy.
    /// Unicode bullet chars chosen for their fixed-width rendering
    /// in macOS menus.
    private func statusDot(for monitor: InstanceHealthMonitor?) -> String {
        guard let monitor else { return "○" }   // never attached
        if monitor.isHealthy { return "🟢" }
        // No second-tier "stale" state visible at the menu level —
        // monitor.isHealthy is the union of "we've heard back recently
        // AND the response was 200." Anything else is red.
        return "🔴"
    }

    // MARK: - Service-update section (.app updater, unchanged from M0)

    @ViewBuilder
    private var updateSection: some View {
        switch updates.status {
        case .idle:
            // Manual-check affordance. The background poll runs every 30
            // minutes (see UpdateChecker.pollInterval), but expose a
            // user-triggered path too so a user expecting a just-shipped
            // release doesn't have to wait for the next poll.
            Button("Check for updates") {
                Task { await updates.checkNow() }
            }
            Divider()

        case .checking:
            // Mirror .idle's slot with a non-interactive indicator so
            // the row doesn't visually "disappear" the instant a check
            // starts — that would be a confusing UX (button vanishes
            // → user assumes click failed).
            Text("Checking for updates…")
                .foregroundStyle(.secondary)
            Divider()

        case .available(let version, _):
            Text("● Service update available: v\(version)")
            Button("Apply Update") {
                Task { await updates.applyUpdate() }
            }
            Divider()

        case .applying(let version, let stage):
            Text("Updating to v\(version) — \(stage)…")
                .foregroundStyle(.secondary)
            Divider()

        case .error(let reason):
            Text("⚠ Update failed: \(reason)")
                .foregroundStyle(.red)
            Button("Retry") { Task { await updates.checkNow() } }
            Divider()
        }
    }
}
