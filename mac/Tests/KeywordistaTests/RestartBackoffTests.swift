import XCTest

@testable import Keywordista

/// Pins the auto-restart decision `ServiceSupervisor` makes after the
/// spawned backend exits unexpectedly. The contract:
///
///   • Restart quickly the first time (a one-off crash shouldn't leave
///     the dashboard down for long), then back off exponentially.
///   • Stop retrying after a capped number of crashes inside a time
///     window, so a binary that dies on boot (bad migration, port race)
///     doesn't spin forever burning CPU and filling the logs.
///   • A run that stays up long enough proves the binary is healthy, so
///     the next crash starts the budget over.
///
/// Pure value-type tests — no Process, no clock, no actor hops.
final class RestartBackoffTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private let policy = RestartBackoff.Policy(
        baseDelay: 1,
        maxDelay: 30,
        maxAttempts: 5,
        window: 600,
        stableUptime: 60
    )

    // ── Backoff ──────────────────────────────────────────────────────

    func testFirstCrashRestartsAfterBaseDelay() {
        var backoff = RestartBackoff(policy: policy)

        let decision = backoff.recordCrash(at: t0, uptime: 2)

        XCTAssertEqual(decision, .restart(after: 1, attempt: 1))
    }

    func testRepeatedQuickCrashesDoubleTheDelay() {
        var backoff = RestartBackoff(policy: policy)
        var now = t0
        var delays: [TimeInterval] = []

        for _ in 0..<5 {
            guard case .restart(let delay, _) = backoff.recordCrash(at: now, uptime: 1) else {
                return XCTFail("expected a restart within the attempt budget")
            }
            delays.append(delay)
            now += delay + 1
        }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16])
    }

    func testDelayIsCappedAtMaxDelay() {
        let capped = RestartBackoff.Policy(
            baseDelay: 1, maxDelay: 5, maxAttempts: 10, window: 600, stableUptime: 60
        )
        var backoff = RestartBackoff(policy: capped)
        var now = t0
        var last: RestartBackoff.Decision?

        for _ in 0..<6 {
            last = backoff.recordCrash(at: now, uptime: 1)
            now += 10
        }

        XCTAssertEqual(last, .restart(after: 5, attempt: 6))
    }

    // ── Attempt cap ──────────────────────────────────────────────────

    func testGivesUpOnceAttemptBudgetIsSpent() {
        var backoff = RestartBackoff(policy: policy)
        var now = t0

        for _ in 0..<policy.maxAttempts {
            _ = backoff.recordCrash(at: now, uptime: 1)
            now += 20
        }

        XCTAssertEqual(
            backoff.recordCrash(at: now, uptime: 1),
            .giveUp(attempts: policy.maxAttempts),
            "A binary that keeps dying on boot must not be restarted forever."
        )
    }

    func testCrashesOutsideTheWindowAreForgotten() {
        var backoff = RestartBackoff(policy: policy)

        for i in 0..<policy.maxAttempts {
            _ = backoff.recordCrash(at: t0 + Double(i), uptime: 1)
        }
        let muchLater = t0 + policy.window + 60

        XCTAssertEqual(
            backoff.recordCrash(at: muchLater, uptime: 1),
            .restart(after: 1, attempt: 1)
        )
    }

    // ── Reset on a healthy run ───────────────────────────────────────

    func testLongRunResetsTheBudget() {
        var backoff = RestartBackoff(policy: policy)
        _ = backoff.recordCrash(at: t0, uptime: 1)
        _ = backoff.recordCrash(at: t0 + 5, uptime: 1)
        _ = backoff.recordCrash(at: t0 + 10, uptime: 1)

        let decision = backoff.recordCrash(at: t0 + 100, uptime: policy.stableUptime)

        XCTAssertEqual(decision, .restart(after: 1, attempt: 1))
    }

    func testShortRunDoesNotResetTheBudget() {
        var backoff = RestartBackoff(policy: policy)
        _ = backoff.recordCrash(at: t0, uptime: 1)

        let decision = backoff.recordCrash(at: t0 + 30, uptime: policy.stableUptime - 1)

        XCTAssertEqual(decision, .restart(after: 2, attempt: 2))
    }

    func testResetClearsHistory() {
        var backoff = RestartBackoff(policy: policy)
        for i in 0...policy.maxAttempts {
            _ = backoff.recordCrash(at: t0 + Double(i), uptime: 1)
        }

        backoff.reset()

        XCTAssertEqual(backoff.recordCrash(at: t0 + 10, uptime: 1), .restart(after: 1, attempt: 1))
    }

    // ── Default policy sanity ────────────────────────────────────────

    func testDefaultPolicyWindowCatchesAnyUnstableLoop() {
        // If a run shorter than `stableUptime` can't reset the budget, the
        // slowest crash loop that still counts spans maxAttempts runs of
        // just-under-stableUptime plus every backoff sleep. The window has
        // to cover that, or a binary that crashes ~50s after boot would
        // slip out of the cap by aging its old crashes out of the window.
        let p = RestartBackoff.Policy.default
        var totalBackoff: TimeInterval = 0
        for attempt in 1...p.maxAttempts {
            totalBackoff += min(p.baseDelay * pow(2, Double(attempt - 1)), p.maxDelay)
        }

        XCTAssertGreaterThan(p.maxAttempts, 0)
        XCTAssertGreaterThanOrEqual(
            p.window,
            Double(p.maxAttempts) * p.stableUptime + totalBackoff
        )
    }
}
