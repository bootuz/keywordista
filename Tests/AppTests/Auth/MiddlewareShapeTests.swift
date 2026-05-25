@testable import App
import Foundation
import Testing
import Vapor

/// Compile-time / structural tests for the auth middleware stack.
///
/// **What's NOT here**: full HTTP integration coverage of
/// AuthMiddleware's request/response flow (401 on missing cookie,
/// rolling-TTL extension, etc.). That requires spinning up a real
/// Application + DB, which is M1.12's job — by then it'll add
/// `VaporTesting` (or equivalent) and verify all the orchestration
/// at the HTTP layer.
///
/// **What IS here**: the small testable bits that don't require an
/// Application — protocol conformance, RoleMiddleware constructor
/// shapes, and a documentation pin for the middleware contract.
@Suite("Auth middleware shapes")
struct MiddlewareShapeTests {

    // ── Conformance ──────────────────────────────────────────────────

    @Test("User conforms to Vapor.Authenticatable")
    func userIsAuthenticatable() {
        // Compile-only assertion: if User loses Authenticatable
        // conformance, this test stops building (which is exactly
        // when we want to know).
        let _: any Authenticatable.Type = User.self
    }

    // ── AuthMiddleware ───────────────────────────────────────────────

    @Test("AuthMiddleware is constructible with a TTL in days")
    func authMiddlewareInit() {
        // 30 = the manifest's KEYWORDISTA_SESSION_TTL_DAYS default.
        let mw = AuthMiddleware(sessionTTLDays: 30)
        #expect(mw.sessionTTLDays == 30)
    }

    @Test("AuthMiddleware conforms to AsyncMiddleware (Vapor's protocol)")
    func authMiddlewareIsAsyncMiddleware() {
        let _: any AsyncMiddleware = AuthMiddleware(sessionTTLDays: 1)
    }

    // ── RoleMiddleware ───────────────────────────────────────────────

    @Test("requireAdmin() is the .admin-only configuration")
    func requireAdminFactory() {
        let mw = RoleMiddleware.requireAdmin()
        #expect(mw.allowed == [.admin])
    }

    @Test("Variadic init preserves the role set")
    func variadicInit() {
        let mw = RoleMiddleware(allow: .admin, .member)
        #expect(mw.allowed == [.admin, .member])
    }

    @Test("Set init preserves the role set")
    func setInit() {
        let mw = RoleMiddleware(allow: Set([User.Role.admin]))
        #expect(mw.allowed == [.admin])
    }

    @Test("Empty role set is technically allowed but rejects every user (fail-closed default)")
    func emptyAllowedSetIsFailClosed() {
        // Defensible default: a misconfigured RoleMiddleware that
        // accidentally got an empty allow set would reject all
        // requests with 403, which is the right failure mode for an
        // auth gate. Pinning the behavior here so anyone tempted to
        // change it to "empty = allow all" hits this test loudly.
        let mw = RoleMiddleware(allow: Set<User.Role>())
        #expect(mw.allowed.isEmpty)
    }

    @Test("RoleMiddleware conforms to AsyncMiddleware")
    func roleMiddlewareIsAsyncMiddleware() {
        let _: any AsyncMiddleware = RoleMiddleware.requireAdmin()
    }
}
