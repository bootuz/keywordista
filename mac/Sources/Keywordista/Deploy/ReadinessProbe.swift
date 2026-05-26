import Foundation

/// Post-deploy verification that a freshly-deployed Keywordista server
/// is **fully serving**, not just health-checking.
///
/// **The bug this exists to prevent**: the provider's deploy stream
/// emits `.healthCheckPassed` the instant `GET /health` returns 200,
/// but Vapor registers `/health` *before* mounting auth routes. There
/// is a 1–5 second window where `/health` is up but `/api/v1/auth/state`
/// still 503s. If the cockpit transitions to the success screen during
/// that window, the user clicks "Open dashboard" and lands on a broken
/// login page — eroding trust in the "it just worked" moment that the
/// whole one-click flow is built around.
///
/// This probe closes the window by polling `/api/v1/auth/state` (a
/// public route under the full middleware stack) until it returns 200,
/// then handing back to the coordinator. If 90s isn't enough, something
/// genuinely went wrong post-health-check (DB migration hung, OOM during
/// route registration, config crash mid-boot) and we surface the failure
/// rather than silently advancing.
///
/// **Why `/api/v1/auth/state` and not `/api/v1/version`**: both would
/// work, but `/auth/state` exercises the *auth middleware stack* — the
/// thing that, if not mounted, breaks every screen the user is about to
/// see. `/version` is too thin a probe.
///
/// **Why poll instead of WebSocket / SSE**: providers' upstream proxies
/// have widely varying buffering/upgrade behavior in the seconds after a
/// new deploy. Plain polling is boring and works on every PaaS we'll
/// ever care about. The probe is short-lived (90s ceiling) so the
/// overhead is trivial.
enum ReadinessProbe {

    /// 90s is generous for a Render Starter cold start while doing DB
    /// migrations on first boot. If we still 503 after that, something
    /// is genuinely wrong and the user needs to see the provider logs.
    static let timeout: TimeInterval = 90

    /// Poll every 3s. Per-iteration wall time is therefore at most
    /// `requestTimeout + interval` = 2 + 3 = 5s. Worst case across the
    /// 90s budget: 90/5 ≈ 18 attempts when probes saturate the
    /// per-request cap; ~30 attempts when probes reject quickly
    /// (TCP-refused / fast 503). Earlier comment claimed "30 attempts"
    /// unconditionally — that was wrong when the server is slow,
    /// which is exactly when the probe matters most. M3.24a tightened
    /// `requestTimeout` from 5→2s to bring the worst case back close
    /// to the 30-attempt mental model.
    static let interval: TimeInterval = 3

    /// Per-request timeout. Kept BELOW `interval` so a single slow
    /// probe doesn't push the next attempt past the natural polling
    /// tick. 2s is enough for any HTTP exchange against a co-located
    /// PaaS frontend; a server still answering slower than 2s on the
    /// auth-state path is already in trouble — we'd rather count that
    /// as a failed probe and try again than burn the 5s and skew the
    /// iteration cadence.
    static let requestTimeout: TimeInterval = 2

    enum Outcome: Equatable {
        case ready
        case timedOut
        case cancelled
    }

    /// Polls `baseURL/api/v1/auth/state` until it returns 200 or the
    /// timeout expires. `statusSink` receives human-readable progress
    /// updates the coordinator can surface in the deploy log panel.
    ///
    /// Cooperatively cancellable via standard `Task` cancellation —
    /// returns `.cancelled` cleanly if the deploy flow is torn down
    /// mid-probe.
    static func waitForReady(
        baseURL: URL,
        clock: any ProbeClock = SystemProbeClock(),
        session: URLSession = .shared,
        statusSink: @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> Outcome {
        let deadline = clock.now.addingTimeInterval(timeout)
        var attempt = 0

        while clock.now < deadline {
            if Task.isCancelled { return .cancelled }
            attempt += 1

            let elapsed = Int(timeout - deadline.timeIntervalSince(clock.now))
            await statusSink(
                "Verifying auth routes (attempt \(attempt), \(elapsed)s)…"
            )

            if await probe(baseURL: baseURL, session: session) {
                await statusSink("Server ready.")
                return .ready
            }

            // Sleep for `interval` seconds, honoring cancellation.
            // Task.sleep throws on cancel, which is exactly what we
            // want — the next loop iteration returns .cancelled.
            do {
                try await clock.sleep(seconds: interval)
            } catch {
                return .cancelled
            }
        }

        return .timedOut
    }

    /// Single attempt at `GET baseURL/api/v1/auth/state`. Returns true
    /// iff the response is HTTP 200. Any error (timeout, refused,
    /// non-200 status, malformed response) returns false — the caller
    /// retries until the deadline.
    static func probe(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> Bool {
        let url = baseURL.appendingPathComponent("api/v1/auth/state")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = requestTimeout
        // Defensive: don't follow redirects silently. A provider's edge
        // proxy occasionally redirects mid-deploy; we want to see the
        // 30x, not chase it.
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}

/// Test seam: lets ReadinessProbeTests drive a virtual clock so the
/// 90s timeout doesn't need 90s of wall time to verify. Production
/// uses `SystemProbeClock` which delegates to `Date()` + `Task.sleep`.
protocol ProbeClock: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

struct SystemProbeClock: ProbeClock {
    var now: Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
