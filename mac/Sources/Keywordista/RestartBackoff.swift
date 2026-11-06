import Foundation

// Decides whether ServiceSupervisor should relaunch the backend after an
// unexpected exit, and how long to wait first.
//
// A plain value type with no clock of its own — the caller passes `now`
// and the run's uptime — so the policy can be unit-tested without a real
// Process or real sleeps.
struct RestartBackoff: Equatable, Sendable {
    struct Policy: Equatable, Sendable {
        var baseDelay: TimeInterval
        var maxDelay: TimeInterval
        // Restarts allowed inside `window` before we give up and leave the
        // supervisor `.crashed` for the user to look at.
        var maxAttempts: Int
        var window: TimeInterval
        // A run this long counts as healthy and clears the crash history,
        // so a server that crashes once a week always gets a fast restart.
        var stableUptime: TimeInterval

        // 1s, 2s, 4s, 8s, 16s, then give up. Why these numbers: the first
        // retry is quick enough that a one-off crash is barely noticeable;
        // five tries covers a port race or a slow-to-release SQLite lock;
        // a binary that fails all five is broken (bad migration, corrupt
        // download) and retrying further only fills the logs. The window
        // is wide enough that a crash loop slower than the backoff (a
        // server dying ~50s after boot) still hits the cap — see
        // RestartBackoffTests.testDefaultPolicyWindowCatchesAnyUnstableLoop.
        static let `default` = Policy(
            baseDelay: 1,
            maxDelay: 30,
            maxAttempts: 5,
            window: 600,
            stableUptime: 60
        )
    }

    enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval, attempt: Int)
        case giveUp(attempts: Int)
    }

    let policy: Policy
    private(set) var recentCrashes: [Date] = []

    init(policy: Policy = .default) {
        self.policy = policy
    }

    mutating func recordCrash(at now: Date, uptime: TimeInterval) -> Decision {
        if uptime >= policy.stableUptime {
            recentCrashes.removeAll()
        }
        recentCrashes.removeAll { now.timeIntervalSince($0) > policy.window }
        recentCrashes.append(now)

        let attempt = recentCrashes.count
        guard attempt <= policy.maxAttempts else {
            return .giveUp(attempts: policy.maxAttempts)
        }
        let delay = min(policy.baseDelay * pow(2, Double(attempt - 1)), policy.maxDelay)
        return .restart(after: delay, attempt: attempt)
    }

    mutating func reset() {
        recentCrashes.removeAll()
    }
}
