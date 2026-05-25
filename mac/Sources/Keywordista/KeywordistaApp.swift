import AppKit
import Combine
import SwiftUI

/// App-wide service owner. Rewritten in M3.13 to manage the multi-
/// instance world (M3.1's InstanceStore + M3.2's HealthCoordinator
/// + M3.6's RenderProvider + M3.12's InstanceLifecycle) instead of
/// the pre-M3 single-local-instance world.
///
/// **Lifecycle commitments**:
///   • The local backend (ServiceSupervisor) auto-syncs into
///     InstanceStore on every port change — Combine subscription on
///     supervisor.$port. The local Instance carries a stable hardcoded
///     UUID so its identity is constant across launches.
///   • HealthCoordinator.reconcile is called on every InstanceStore
///     change. New instances get monitors; removed ones get their
///     monitors detached. No reconcile leaks.
///   • The deploy-flow + add-existing coordinators are created
///     on-demand (one per wizard attempt) and dropped on completion.
@MainActor
final class AppCoordinator: ObservableObject {

    // Long-lived services
    let supervisor: ServiceSupervisor
    let instanceStore: InstanceStore
    let health: HealthCoordinator
    let loginItems: LoginItemManager
    let updates: UpdateChecker
    let lifecycle: InstanceLifecycle
    let providers: [any Provider]

    // Per-attempt coordinators. `@Published` so the WindowGroup body
    // re-evaluates and renders the right wizard once we create one.
    @Published var deployFlowCoordinator: DeployFlowCoordinator?
    @Published var addExistingCoordinator: AddExistingCoordinator?

    private var cancellables: Set<AnyCancellable> = []

    /// Stable UUID for the local instance. Hardcoded so it's the same
    /// across launches — without this, a fresh UUID each boot would
    /// orphan the previous run's instances.json entry (and its
    /// Keychain session-cookie reference, if any).
    static let localInstanceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    init() {
        // Long-lived services first. Order matters slightly — providers
        // is captured into lifecycle, so it needs to exist first.
        let supervisor = ServiceSupervisor()
        let instanceStore = InstanceStore()
        let health = HealthCoordinator()
        let providers: [any Provider] = [RenderProvider()]
        let lifecycle = InstanceLifecycle(
            instanceStore: instanceStore,
            health: health,
            providers: providers
        )

        // UpdateChecker is unchanged from M0 — still binds to the
        // single supervisor (it's the .app updater, not a remote
        // service updater).
        let updates = UpdateChecker()
        updates.bind(to: supervisor)
        updates.start()

        self.supervisor = supervisor
        self.instanceStore = instanceStore
        self.health = health
        self.loginItems = LoginItemManager()
        self.updates = updates
        self.lifecycle = lifecycle
        self.providers = providers

        // ── Reactive wiring ──────────────────────────────────────

        // Sync local instance into InstanceStore on every supervisor
        // port change. The supervisor publishes `port` as @Published,
        // so we get a value immediately on subscribe (with whatever
        // port the supervisor settled on) plus any fallback events
        // (8080 busy → falls back to 8081 etc.).
        supervisor.$port
            .sink { [weak self] port in
                self?.upsertLocalInstance(port: port)
            }
            .store(in: &cancellables)

        // Reconcile health monitors with the instance list every time
        // it changes. Adds monitors for new instances; detaches them
        // for removed ones. Unchanged instances keep their monitor
        // (no health-status flicker on unrelated mutations).
        instanceStore.$instances
            .sink { [weak self] instances in
                self?.health.reconcile(with: instances)
            }
            .store(in: &cancellables)
    }

    /// Adds the local instance to the store on first run, OR updates
    /// its baseURL if the supervisor's port changed. Idempotent.
    private func upsertLocalInstance(port: UInt16) {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let local = Instance(
            id: Self.localInstanceID,
            kind: .local(LocalInstance(baseURL: url))
        )
        if instanceStore.instances.contains(where: { $0.id == Self.localInstanceID }) {
            try? instanceStore.update(local)
        } else {
            try? instanceStore.add(local)
        }
    }

    // MARK: - Window factory methods
    //
    // Wizard windows are opened via @Environment(\.openWindow) at the
    // call site (the App body). These methods construct the per-
    // attempt coordinator and store it so the WindowGroup body can
    // see it.

    func startDeployFlow() {
        deployFlowCoordinator = DeployFlowCoordinator(
            providers: providers,
            onCompletion: { [weak self] instance in
                guard let self else { return }
                try? self.instanceStore.add(instance)
                // The window dismisses itself via .dismissWindow in
                // SuccessView's completion path. Coordinator stays
                // until next startDeployFlow() replaces it.
            }
        )
    }

    func startAddExisting() {
        addExistingCoordinator = AddExistingCoordinator(
            onCompletion: { [weak self] instance, sessionCookie in
                guard let self else { return }
                try? self.instanceStore.add(instance)
                try? KeychainStore.setSessionCookie(sessionCookie, instanceID: instance.id)
            }
        )
    }

    // MARK: - Destructive actions with confirm
    //
    // NSAlert because menubar callbacks fire outside any SwiftUI
    // view context — .confirmationDialog doesn't have a view to
    // attach to. NSAlert.runModal blocks the main thread, which is
    // fine here (the user clicked a destructive button; we WANT
    // them blocked from clicking anything else until they decide).

    func confirmDisconnect(_ instance: Instance) {
        let alert = NSAlert()
        alert.messageText = "Disconnect \(instance.displayName)?"
        alert.informativeText = "The deployment will keep running on the provider; it just won't appear in your menubar anymore. You can re-add it later via 'Add existing deployment'."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            lifecycle.disconnect(instance)
        }
    }

    func confirmDelete(_ instance: Instance) {
        let alert = NSAlert()
        alert.messageText = "Delete \(instance.displayName)?"
        alert.informativeText = """
            This will destroy the deployment on the provider AND delete its database. This cannot be undone.

            If you just want to remove it from your menubar without affecting the server, use Disconnect instead.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.lifecycle.delete(instance)
            } catch {
                self.showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't complete that action"
        // Prefer typed-error descriptions (LifecycleError + ProviderError
        // both conform via custom messages); fall back to Swift's stock
        // localizedDescription for system errors. The "as? Custom..."
        // cast was warned about because every Error has localizedDescription;
        // here we check for our typed errors explicitly.
        if let typed = error as? LifecycleError {
            alert.informativeText = typed.description
        } else if let typed = error as? ProviderError {
            alert.informativeText = typed.description
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - App entry point

/// Menubar app entry. Owns the three Scenes:
///   • MenuBarExtra — the dropdown when the user clicks the menubar icon
///   • WindowGroup(id: "deploy-flow") — the deploy wizard
///   • WindowGroup(id: "add-existing") — the import-existing form
///
/// **Window discipline**: we use WindowGroup (not Window) because
/// Window is macOS 14+ and the menubar app's deployment target is
/// macOS 13. WindowGroup creates a new window per openWindow call,
/// so theoretically the user could double-click "Deploy to a server…"
/// and open two wizards. Accepted as an edge case for v1; the
/// per-attempt coordinator pattern handles state correctly even if
/// it happens.
@main
struct KeywordistaApp: App {
    @StateObject private var coord = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coord: coord)
        } label: {
            Image(systemName: iconName(for: coord.updates.status))
        }

        WindowGroup(id: "deploy-flow") {
            if let dfc = coord.deployFlowCoordinator {
                DeployFlowWindow(coordinator: dfc)
            } else {
                // Defensive — shouldn't be reachable because we only
                // openWindow after startDeployFlow() runs. Renders
                // a placeholder rather than crashing.
                Text("Deploy flow not initialized")
                    .frame(width: 580, height: 680)
            }
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "add-existing") {
            if let aec = coord.addExistingCoordinator {
                AddExistingWindow(coordinator: aec)
            } else {
                Text("Import flow not initialized")
                    .frame(width: 460, height: 360)
            }
        }
        .windowResizability(.contentSize)
    }

    /// Menubar icon — three modes. Pre-M3 had only the magnifying
    /// glass + badged version for service updates; v2 uses
    /// HealthCoordinator's rollupStatus to surface "any instance is
    /// down" without opening the menu.
    private func iconName(for status: UpdateStatus) -> String {
        switch coord.health.rollupStatus {
        case .green:
            return status.hasNotification
                ? "magnifyingglass.circle.fill"
                : "magnifyingglass"
        case .yellow:
            return "magnifyingglass.circle"
        case .red:
            return "exclamationmark.magnifyingglass"
        }
    }
}

/// Thin view that pulls the openWindow environment value and wires
/// the menu's onDeploy/onAddExisting callbacks. Lives in its own
/// View so the @Environment access works correctly — MenuBarExtra's
/// closure doesn't have access to @Environment values directly.
private struct MenuBarContent: View {
    @ObservedObject var coord: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuView_v2(
            instanceStore: coord.instanceStore,
            health: coord.health,
            supervisor: coord.supervisor,
            loginItems: coord.loginItems,
            updates: coord.updates,
            onDeploy: {
                coord.startDeployFlow()
                openWindow(id: "deploy-flow")
            },
            onAddExisting: {
                coord.startAddExisting()
                openWindow(id: "add-existing")
            },
            onDisconnect: { coord.confirmDisconnect($0) },
            onDelete: { coord.confirmDelete($0) }
        )
    }
}

private extension UpdateStatus {
    /// True when there's a service-update event worth surfacing in
    /// the menubar icon (a badge). Idle/checking don't warrant
    /// visual noise.
    var hasNotification: Bool {
        switch self {
        case .available, .applying, .error: return true
        case .idle, .checking: return false
        }
    }
}
