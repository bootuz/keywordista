import XCTest
import os.lock

@testable import Keywordista

/// Pins the M3.20 fully-serving probe contract. The bug this exists
/// to prevent: the cockpit transitioned to the success screen the
/// instant Render's `/health` returned 200, but Vapor mounts `/health`
/// *before* auth routes — leaving a 1–5s window where the user clicks
/// "Open dashboard" and lands on a broken login page. This test file
/// pins:
///   - The probe URL path (`/api/v1/auth/state`, not `/health`)
///   - The retry behavior (returns ready on first 200)
///   - The timeout behavior (returns timedOut after deadline)
///   - The cancellation behavior (returns cancelled on Task.cancel)
///
/// Uses a virtual clock + a custom URLSession with URLProtocol mock
/// so the 90s real timeout doesn't burn 90s of wall time in CI.
final class ReadinessProbeTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockProbeURLProtocol.reset()
    }

    // ── URL construction (pure function) ─────────────────────────────

    func testProbesAuthStateNotHealth() async {
        // The whole reason this probe exists: /health is too eager.
        // We must hit /api/v1/auth/state instead. Pin the path.
        var requestedPaths: [String] = []
        MockProbeURLProtocol.handler = { request in
            requestedPaths.append(request.url?.path ?? "")
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!, Data())
        }

        _ = await ReadinessProbe.probe(
            baseURL: URL(string: "https://example.com")!,
            session: mockSession()
        )

        XCTAssertEqual(requestedPaths, ["/api/v1/auth/state"])
    }

    func testProbesPreserveBaseURLHostAndScheme() async {
        // baseURL may have a path component (e.g. http://example.com/some/prefix).
        // Don't lose it.
        var capturedURL: URL?
        MockProbeURLProtocol.handler = { request in
            capturedURL = request.url
            return (HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!, Data())
        }

        _ = await ReadinessProbe.probe(
            baseURL: URL(string: "https://kw.example.com:8443")!,
            session: mockSession()
        )

        XCTAssertEqual(capturedURL?.scheme, "https")
        XCTAssertEqual(capturedURL?.host, "kw.example.com")
        XCTAssertEqual(capturedURL?.port, 8443)
        XCTAssertEqual(capturedURL?.path, "/api/v1/auth/state")
    }

    // ── probe() outcome mapping ──────────────────────────────────────

    func testProbeReturnsTrueOn200() async {
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let ready = await ReadinessProbe.probe(
            baseURL: URL(string: "https://example.com")!,
            session: mockSession()
        )
        XCTAssertTrue(ready)
    }

    func testProbeReturnsFalseOn503() async {
        // The exact failure mode this probe guards against — auth routes
        // not mounted yet, so /api/v1/auth/state 503s.
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let ready = await ReadinessProbe.probe(
            baseURL: URL(string: "https://example.com")!,
            session: mockSession()
        )
        XCTAssertFalse(ready)
    }

    func testProbeReturnsFalseOnConnectionError() async {
        // Simulates the connection-refused phase that some providers
        // hit right after a deploy promotion (load balancer hasn't
        // routed yet). Probe should treat as not-ready and let the
        // outer loop retry.
        MockProbeURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let ready = await ReadinessProbe.probe(
            baseURL: URL(string: "https://example.com")!,
            session: mockSession()
        )
        XCTAssertFalse(ready)
    }

    // ── waitForReady() loop behavior ─────────────────────────────────

    func testWaitForReadyReturnsReadyOnFirstSuccess() async {
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let clock = FakeProbeClock()
        let outcome = await ReadinessProbe.waitForReady(
            baseURL: URL(string: "https://example.com")!,
            clock: clock,
            session: mockSession()
        )
        XCTAssertEqual(outcome, .ready)
    }

    func testWaitForReadyRetriesUntilSuccess() async {
        // Boot trace: server 503s for first two attempts, then ready.
        // Pin that we don't give up on the first miss and that the
        // attempt counter advances.
        let attemptCount = AttemptCounter()
        MockProbeURLProtocol.handler = { request in
            let n = attemptCount.increment()
            let status = n < 3 ? 503 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = FakeProbeClock()
        let outcome = await ReadinessProbe.waitForReady(
            baseURL: URL(string: "https://example.com")!,
            clock: clock,
            session: mockSession()
        )

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(attemptCount.value, 3)
        // Each retry advances the virtual clock by the polling interval.
        // 2 retries = 2 sleeps. (Third probe succeeds; we don't sleep
        // after success.)
        XCTAssertEqual(clock.sleeps.count, 2)
        XCTAssertEqual(clock.sleeps.first, ReadinessProbe.interval)
    }

    func testWaitForReadyTimesOutAfterDeadline() async {
        // Server stays 503 forever. Probe should give up after the
        // configured timeout and return .timedOut so the coordinator
        // can surface a "check provider logs" failure rather than
        // silently advancing to a broken success screen.
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503,
                             httpVersion: nil, headerFields: nil)!, Data())
        }

        let clock = FakeProbeClock()
        let outcome = await ReadinessProbe.waitForReady(
            baseURL: URL(string: "https://example.com")!,
            clock: clock,
            session: mockSession()
        )

        XCTAssertEqual(outcome, .timedOut)
        // Verifies the deadline was respected — should have slept
        // ~timeout/interval times (with off-by-one tolerance).
        let expectedSleeps = Int(ReadinessProbe.timeout / ReadinessProbe.interval)
        XCTAssertGreaterThanOrEqual(clock.sleeps.count, expectedSleeps - 1)
        XCTAssertLessThanOrEqual(clock.sleeps.count, expectedSleeps + 1)
    }

    // ── Cancellation (M3.24a) ────────────────────────────────────────

    func testWaitForReadyReturnsCancelledWhenTaskCancelled() async {
        // The .cancelled outcome path was structurally unreachable in
        // the original M3.20 test suite — FakeProbeClock.sleep didn't
        // throw, so the production `catch { return .cancelled }` was
        // dead code from a test perspective. M3.24a hardened the clock
        // to honor Task.checkCancellation; this test exercises the
        // path the cockpit's cancel-mid-probe scenario depends on.
        //
        // Production behavior: when the user clicks Cancel during the
        // 90s probe window, the parent Task is cancelled → the next
        // clock.sleep throws → waitForReady catches and returns
        // .cancelled → the coordinator transitions to .failed (M3.24a
        // also fixed the previously-stuck .deploying phase here).
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503,
                             httpVersion: nil, headerFields: nil)!, Data())
        }

        let session = mockSession()
        let task = Task<ReadinessProbe.Outcome, Never> {
            await ReadinessProbe.waitForReady(
                baseURL: URL(string: "https://example.com")!,
                clock: FakeProbeClock(),
                session: session
            )
        }
        // Cancel before the first probe completes a sleep cycle.
        // Task.cancel is cooperative; the throw inside clock.sleep
        // unblocks the loop, which returns .cancelled.
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled,
                      "Cancelled task must return .cancelled, not .timedOut or .ready")
    }

    // ── statusSink wiring ────────────────────────────────────────────

    @MainActor
    func testStatusSinkReceivesProgressMessages() async {
        MockProbeURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data())
        }

        let collector = MainActorStatusCollector()
        _ = await ReadinessProbe.waitForReady(
            baseURL: URL(string: "https://example.com")!,
            clock: FakeProbeClock(),
            session: mockSession(),
            statusSink: { @MainActor message in collector.append(message) }
        )

        let messages = await collector.snapshot
        // Should have at least one "Verifying…" attempt + the final
        // "Server ready." marker.
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.last?.contains("ready") ?? false,
                     "expected final message to mention 'ready', got \(messages)")
    }

    // MARK: - Helpers

    private func mockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockProbeURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

// MARK: - Test doubles

/// Counts increments across concurrent calls. NSLock keeps it valid
/// under Swift 6's strict-concurrency checking without forcing the
/// closure that uses it to be MainActor.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _value += 1
        return _value
    }
}

/// MainActor-isolated collector — paired with a `@MainActor` status
/// sink, which is what the production cockpit uses (the sink writes
/// into a @Published property on the @MainActor coordinator).
@MainActor
private final class MainActorStatusCollector {
    private var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
    var snapshot: [String] { messages }
}

/// Virtual clock — `sleep(seconds:)` advances `now` instead of waiting
/// real wall-time. Lets the 90s-real-timeout tests run in milliseconds.
///
/// Uses `OSAllocatedUnfairLock` (vs. NSLock) because the lock is
/// acquired inside an `async` method — NSLock triggers a Swift 6
/// future-error warning in async contexts, OSAllocatedUnfairLock is
/// the async-safe replacement available since macOS 13.
private final class FakeProbeClock: ProbeClock, @unchecked Sendable {
    private struct State {
        var now: Date = Date(timeIntervalSince1970: 1_000_000_000)
        var sleeps: [TimeInterval] = []
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var now: Date { state.withLock { $0.now } }
    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }

    func sleep(seconds: TimeInterval) async throws {
        // M3.24a: honor cooperative cancellation. Previously this just
        // advanced the virtual clock — meaning the production
        // `catch { return .cancelled }` branch in waitForReady was
        // structurally unreachable from tests using this clock.
        // The whole point of the .cancelled outcome is that
        // production's `Task.sleep` throws when the enclosing task
        // is cancelled; the fake clock should mirror that contract
        // so cancellation tests can exercise the same code path.
        try Task.checkCancellation()
        state.withLock { s in
            s.sleeps.append(seconds)
            s.now = s.now.addingTimeInterval(seconds)
        }
    }
}

/// URLProtocol stub that intercepts every request from sessions
/// configured with it in `protocolClasses`. The handler is set per-test
/// and returns whatever response/error shape the test needs.
final class MockProbeURLProtocol: URLProtocol, @unchecked Sendable {
    /// Set per test. Either returns (response, body) or throws.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = MockProbeURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
