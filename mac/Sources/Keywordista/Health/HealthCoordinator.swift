import Foundation
import SwiftUI

/// Owns one `InstanceHealthMonitor` per Instance the app is tracking.
/// Mirrors InstanceStore's add/remove operations: when an instance
/// joins the store, attach a monitor; when it leaves, detach.
///
/// **Why a separate coordinator** instead of embedding the monitor
/// in Instance directly: Instance is `Codable` and persisted to
/// disk; InstanceHealthMonitor holds a live Task and `URLSession`
/// reference — runtime-only state. Mixing them would either force
/// Instance to be non-Codable, or force the monitor's transient
/// fields to be Codable-but-ignored. Clean separation: Instance is
/// the persisted record, HealthCoordinator owns the runtime mirror.
///
/// **Why @MainActor**: every consumer is a SwiftUI view (or the
/// menubar app delegate). Driving the @Published mutations from the
/// MainActor avoids cross-actor isolation hops for every UI update.
@MainActor
final class HealthCoordinator: ObservableObject {

    /// Keyed by Instance.id so views can look up "the monitor for
    /// this instance" without holding a reference to the monitor
    /// itself. @Published so adding/removing an instance triggers
    /// a re-render of any view that subscribes to the coordinator.
    @Published private(set) var monitors: [UUID: InstanceHealthMonitor] = [:]

    /// Creates and starts a monitor for the given instance. Idempotent:
    /// calling twice with the same instance.id replaces the existing
    /// monitor (the previous one is stopped, releasing its Task).
    ///
    /// Cadence is chosen from the instance kind — local gets the fast
    /// 2s poll the menubar's "did the server start yet?" check needs;
    /// remote gets the polite 30s to respect provider rate limits.
    func attach(_ instance: Instance) {
        // Stop any existing monitor first so two Tasks don't race
        // against the same instance after re-attachment.
        monitors[instance.id]?.stop()

        let interval: TimeInterval = switch instance.kind {
        case .local: HealthPollInterval.local
        case .remote: HealthPollInterval.remote
        }
        let monitor = InstanceHealthMonitor(url: instance.baseURL, interval: interval)
        monitor.start()
        monitors[instance.id] = monitor
    }

    /// Stops the monitor for the given id and removes it from the
    /// dictionary. Idempotent — detaching an unknown id is a no-op
    /// (matches the InstanceStore.remove semantics).
    func detach(id: UUID) {
        monitors[id]?.stop()
        monitors[id] = nil
    }

    /// Reconciles the coordinator's monitors with a fresh list of
    /// instances. Called by the boot wiring (M3.13) and any time
    /// InstanceStore.instances changes. Net effect:
    ///   • New instances → attach
    ///   • Removed instances → detach
    ///   • Existing instances → unchanged (poll continues)
    ///
    /// We use Set diffs rather than wholesale tear-down+rebuild so
    /// an unchanged instance doesn't lose its in-flight ping state
    /// (and its green dot doesn't flicker red for a moment on every
    /// InstanceStore mutation).
    func reconcile(with instances: [Instance]) {
        let desired = Set(instances.map(\.id))
        let current = Set(monitors.keys)

        for removedID in current.subtracting(desired) {
            detach(id: removedID)
        }
        for instance in instances where !current.contains(instance.id) {
            attach(instance)
        }
    }

    /// Convenience for views: returns the monitor for the given
    /// instance, or nil if none is attached (shouldn't normally
    /// happen, but lets views guard rather than crash).
    func monitor(for id: UUID) -> InstanceHealthMonitor? {
        monitors[id]
    }

    // MARK: - Rollup status (for the menubar icon)

    /// Aggregate health across all monitors. Drives the menubar
    /// icon's color: green if every monitor is healthy, yellow if
    /// any are stale, red if every monitor is unhealthy. Empty
    /// (no instances) → .green to avoid a sad icon on first run
    /// before any local supervisor reports in.
    var rollupStatus: RollupStatus {
        guard !monitors.isEmpty else { return .green }
        let healthyCount = monitors.values.filter(\.isHealthy).count
        if healthyCount == monitors.count { return .green }
        if healthyCount == 0 { return .red }
        return .yellow
    }
}

/// Three-color summary for the menubar status icon.
enum RollupStatus {
    case green
    case yellow
    case red
}
