import Foundation
import SwiftUI

/// Per-instance health poller. Generalizes the pre-M3 HealthMonitor
/// (which assumed exactly one local backend on a fixed port) to any
/// Instance's baseURL with a configurable poll interval.
///
/// **Lifecycle**: HealthCoordinator owns one of these per Instance.
/// `start()` is called on attach; `stop()` is called on detach.
/// The internal Task ticks on its own schedule — independent of
/// other monitors so a slow remote doesn't block local polling.
///
/// **Why per-instance Tasks instead of one central loop**: jitter
/// independence. A 1.5s timeout on a slow Render box shouldn't push
/// the local instance's next ping out by 1.5s. Each monitor's Task
/// schedules its own sleep + ping. ≤10 monitors per machine — the
/// cost of N tasks is trivial; the win is no head-of-line blocking
/// and clean cancellation when an instance is removed.
@MainActor
final class InstanceHealthMonitor: ObservableObject {

    /// Last time a successful 200 came back. nil until the first ping
    /// returns; `isHealthy` uses this + staleThreshold to decide.
    @Published private(set) var lastPingOk: Date?

    /// Last time a ping failed (network error, non-200, timeout). Kept
    /// separately so the menu can show "stale for 10s" rather than
    /// just "not currently healthy."
    @Published private(set) var lastPingFailed: Date?

    private let url: URL
    private let interval: TimeInterval
    /// Derived: 2.5× poll interval. Tolerates one missed ping (e.g.
    /// the deployed server doing a brief GC pause) without flapping
    /// to unhealthy. Hardcoding seconds here would mis-tune one
    /// cadence or the other — local at 2s wants ~5s, remote at 30s
    /// wants ~75s.
    private let staleThreshold: TimeInterval

    private var task: Task<Void, Never>?

    init(url: URL, interval: TimeInterval) {
        self.url = url
        self.interval = interval
        self.staleThreshold = interval * 2.5
    }

    /// Current health, computed against staleThreshold. Returns false
    /// before the first successful ping (lastPingOk is nil).
    var isHealthy: Bool {
        guard let last = lastPingOk else { return false }
        return Date().timeIntervalSince(last) < staleThreshold
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.ping()
                // Convert interval (seconds) to nanoseconds for Task.sleep.
                // Truncating to UInt64 is safe — we'd never set interval
                // larger than ~5_000s here.
                let nanos = UInt64(self.interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func ping() async {
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.timeoutInterval = min(interval, 5.0)  // never block longer than a poll cycle
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                lastPingOk = Date()
            } else {
                lastPingFailed = Date()
            }
        } catch {
            // Treat network errors, timeouts, DNS failures all the same:
            // "we didn't hear back." Surfacing the error category to
            // the menu UI hasn't proven valuable in practice — the user
            // just wants the green/red dot.
            lastPingFailed = Date()
        }
    }
}

// MARK: - Polling cadences

/// Centralized cadence policy. Lives here (not at the call site) so
/// future tuning (e.g. backoff on consecutive failures, longer polls
/// for instances that haven't been opened in a week) has one obvious
/// place to land.
enum HealthPollInterval {
    /// 2s — the pre-M3 cadence for the menubar-supervised local
    /// backend. Frequent enough that "starting up after Quit+Relaunch"
    /// shows the green dot within a few seconds.
    static let local: TimeInterval = 2

    /// 30s — restrained polling against deployed PaaS instances. At
    /// 2s polling against a single remote box we'd be hammering
    /// Render/Fly with 43,200 requests/day per machine for almost no
    /// signal. 30s catches outages within "people notice" latency
    /// without being rude to providers — and providers themselves
    /// have ~30s health-check intervals upstream.
    static let remote: TimeInterval = 30
}
