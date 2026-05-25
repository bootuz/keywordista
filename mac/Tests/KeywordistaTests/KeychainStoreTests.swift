import XCTest

@testable import Keywordista

/// Round-trip tests against the real macOS Keychain.
///
/// **These touch system state.** Each test uses a unique random account
/// name (UUID-derived) so concurrent test runs don't collide and a
/// failed test doesn't leak credentials that interfere with the next
/// run. teardown always removes whatever was written.
///
/// **Not covered here**: the prompts that appear when a non-owning
/// process tries to read an item — those require codesigning + a
/// real bundle identity, which the SPM test harness lacks. The
/// access-control gating is exercised by manual QA against a built
/// .app.
final class KeychainStoreTests: XCTestCase {

    private var testAccount: String!

    override func setUp() async throws {
        // Unique account per test so parallel runs don't see each
        // other's writes. UUID is overkill but cheap and self-cleaning.
        testAccount = "test-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        // Best-effort cleanup. Failures are swallowed because some
        // tests delete the item themselves.
        for kind in ProviderKind.allCases {
            try? KeychainStore.removeProviderToken(kind: kind, account: testAccount)
        }
    }

    // ── Provider tokens ──────────────────────────────────────────────

    func testSetAndGetProviderToken() throws {
        try KeychainStore.setProviderToken(
            "rnd_test_token_abc123",
            kind: .render,
            account: testAccount
        )
        let back = try KeychainStore.providerToken(kind: .render, account: testAccount)
        XCTAssertEqual(back, "rnd_test_token_abc123")
    }

    func testSetReplacesExistingValue() throws {
        try KeychainStore.setProviderToken(
            "original",
            kind: .render,
            account: testAccount
        )
        try KeychainStore.setProviderToken(
            "replacement",
            kind: .render,
            account: testAccount
        )
        let back = try KeychainStore.providerToken(kind: .render, account: testAccount)
        XCTAssertEqual(back, "replacement", "set must be idempotent — second call overwrites")
    }

    func testGetReturnsNilForMissing() throws {
        let back = try KeychainStore.providerToken(kind: .render, account: testAccount)
        XCTAssertNil(back)
    }

    func testRemoveIsIdempotent() throws {
        try KeychainStore.setProviderToken(
            "x",
            kind: .render,
            account: testAccount
        )
        try KeychainStore.removeProviderToken(kind: .render, account: testAccount)
        // Second remove must not throw — matches the InstanceStore.remove
        // semantics so cleanup paths can call this without checking first.
        try KeychainStore.removeProviderToken(kind: .render, account: testAccount)
    }

    func testDifferentProvidersAreIsolated() throws {
        try KeychainStore.setProviderToken("render-token", kind: .render, account: testAccount)
        try KeychainStore.setProviderToken("fly-token", kind: .fly, account: testAccount)

        XCTAssertEqual(
            try KeychainStore.providerToken(kind: .render, account: testAccount),
            "render-token"
        )
        XCTAssertEqual(
            try KeychainStore.providerToken(kind: .fly, account: testAccount),
            "fly-token"
        )
    }

    func testDifferentAccountsForSameProviderAreIsolated() throws {
        let a = "account-a-\(UUID().uuidString)"
        let b = "account-b-\(UUID().uuidString)"
        defer {
            try? KeychainStore.removeProviderToken(kind: .render, account: a)
            try? KeychainStore.removeProviderToken(kind: .render, account: b)
        }

        try KeychainStore.setProviderToken("token-for-a", kind: .render, account: a)
        try KeychainStore.setProviderToken("token-for-b", kind: .render, account: b)

        XCTAssertEqual(try KeychainStore.providerToken(kind: .render, account: a), "token-for-a")
        XCTAssertEqual(try KeychainStore.providerToken(kind: .render, account: b), "token-for-b")
    }

    // ── Session cookies ──────────────────────────────────────────────

    func testSessionCookieRoundTrip() throws {
        let instanceID = UUID()
        defer { try? KeychainStore.removeSessionCookie(instanceID: instanceID) }

        try KeychainStore.setSessionCookie("opaque-session-value", instanceID: instanceID)
        XCTAssertEqual(
            try KeychainStore.sessionCookie(instanceID: instanceID),
            "opaque-session-value"
        )
    }

    func testSessionCookiesPerInstanceAreIsolated() throws {
        let a = UUID()
        let b = UUID()
        defer {
            try? KeychainStore.removeSessionCookie(instanceID: a)
            try? KeychainStore.removeSessionCookie(instanceID: b)
        }

        try KeychainStore.setSessionCookie("cookie-a", instanceID: a)
        try KeychainStore.setSessionCookie("cookie-b", instanceID: b)

        XCTAssertEqual(try KeychainStore.sessionCookie(instanceID: a), "cookie-a")
        XCTAssertEqual(try KeychainStore.sessionCookie(instanceID: b), "cookie-b")
    }
}
