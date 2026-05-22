import SwiftUI

// Coordinator that owns the long-lived services and wires their dependencies
// at app launch. SwiftUI's @StateObject can't hand one StateObject to another
// at construction time, so we collapse the three services into a single
// observable owner — @StateObject<AppCoordinator> initializes once at the
// start of the App's lifecycle, and from there we can pass the supervisor's
// port into the health monitor without fighting SwiftUI's init ordering.
@MainActor
final class AppCoordinator: ObservableObject {
    let supervisor: ServiceSupervisor
    let health: HealthMonitor
    let loginItems: LoginItemManager

    init() {
        let supervisor = ServiceSupervisor()
        let health = HealthMonitor()
        // HealthMonitor reads the port fresh on every poll, so by capturing
        // the supervisor reference here (weak so we don't leak across an
        // unrealistic re-init), the menu's pings automatically follow
        // whatever port the supervisor settled on.
        health.portSource = { [weak supervisor] in
            supervisor?.port ?? ServiceSupervisor.preferredPort
        }
        self.supervisor = supervisor
        self.health = health
        self.loginItems = LoginItemManager()
    }
}

// Entry point for the Keywordista menubar app.
//
// Lifecycle:
//   1. @main bootstraps the App and constructs the AppCoordinator inside a
//      @StateObject. The coordinator's init builds ServiceSupervisor (which
//      kicks off the Vapor server child) and wires HealthMonitor's
//      portSource to the supervisor's @Published port.
//   2. LoginItemManager queries SMAppService.mainApp.status synchronously,
//      so the "Launch at login" toggle reflects reality on first open.
//   3. MenuBarExtra renders its label (the menubar icon) immediately and
//      its body only when the user clicks the icon.
@main
struct KeywordistaApp: App {
    @StateObject private var coord = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(coord.supervisor)
                .environmentObject(coord.health)
                .environmentObject(coord.loginItems)
        } label: {
            // SF Symbol template image — automatically follows the menubar
            // appearance (light/dark/accent). Two variants:
            //   default → magnifyingglass (Keywordista's "K-as-ASO-tool" idea)
            //   update available → same glyph with a circle.fill badge
            // We don't have an UpdateChecker plumbed in this scaffold; the
            // label just shows the default icon for now.
            Image(systemName: "magnifyingglass")
        }
    }
}
