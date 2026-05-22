import Foundation
import ServiceManagement
import SwiftUI

// Thin wrapper over SMAppService.mainApp — macOS 13+'s replacement for the
// older SMLoginItemSetEnabled API. The .mainApp variant registers the .app
// itself as a login item; no separate helper bundle needed.
//
// Behavior on first launch: we register automatically (status is .enabled on
// the next session). The user can toggle off via the menu; we honor that and
// remember it through SMAppService's own state (no extra UserDefaults).
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool

    init() {
        self.isEnabled = (SMAppService.mainApp.status == .enabled)
        // Auto-register on first launch only. If the user previously toggled
        // it off, .status is .notRegistered and we leave it alone — the
        // toggle in the menu lets them flip it back on.
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
            self.isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItemManager: SMAppService call failed: \(error)")
        }
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }
}
