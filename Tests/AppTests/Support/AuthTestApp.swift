@testable import App
import Crypto
import Fluent
import FluentSQLiteDriver
import Foundation
import Vapor
import XCTVapor

/// Minimal-server-mode Application factory for M1.12 integration tests.
///
/// Deliberately does NOT go through the production `configure()` —
/// each test wires just enough to exercise the auth + admin surface:
///
///   • in-memory SQLite
///   • all auth migrations (Users, AuthSessions, Invites)
///   • a real SecretBox stashed in app.secretBox
///   • AuthController registered under /api/v1/auth
///   • UsersController registered behind AuthMiddleware →
///     RoleMiddleware.requireAdmin under /api/v1/users
///
/// Tests get a real Vapor Application they can hit with real HTTP
/// via XCTVapor's `app.test(.METHOD, path)` — but with **bcrypt
/// cost 4** (instead of production's 12) so the full integration
/// suite runs in seconds not minutes.
enum AuthTestApp {

    static let publicBaseURL = URL(string: "https://test.kw.local")!
    static let sessionTTLDays = 30
    static let inviteTTLDays = 7
    /// Bcrypt-spec-minimum cost. Same algorithm as production
    /// cost 12 — just dramatically faster (~4ms vs ~250ms).
    static let bcryptCost = 4

    /// Build a fully-wired test Application. Caller is responsible
    /// for `try await app.asyncShutdown()` (use defer).
    ///
    /// - Parameter setupToken: M3.21 — when non-nil, the AuthController
    ///   requires this value in `X-Keywordista-Setup-Token` on the
    ///   /auth/setup request. Default nil = pre-M3.21 behavior so
    ///   existing tests don't have to change.
    static func make(setupToken: String? = nil) async throws -> Application {
        let app = try await Application.make(.testing)

        // ── Storage: in-memory SQLite ────────────────────────────
        app.databases.use(.sqlite(.memory), as: .sqlite)

        // ── App-scoped state mirrors production ──────────────────
        app.secretBox = SecretBox(key: SymmetricKey(size: .bits256))
        app.databaseProvider = .sqlite(path: ":memory:")

        // ── Migrations (the auth-relevant subset) ────────────────
        app.migrations.add(CreateUsers())
        app.migrations.add(CreateAuthSessions())
        app.migrations.add(CreateInvites())
        try await app.autoMigrate()

        // ── Routes: minimum auth surface ─────────────────────────
        let api = app.routes.grouped("api", "v1")

        let authController = AuthController(
            hasher: try PasswordHasher(cost: bcryptCost),
            sessionTTLDays: sessionTTLDays,
            inviteTTLDays: inviteTTLDays,
            // Server mode because the auth tests exercise the
            // protected route surface — local-mode integration
            // (auth-UI hidden, no middleware) is verified
            // separately via routes.swift code review.
            mode: .server,
            setupToken: setupToken
        )
        authController.register(on: api.grouped("auth"))

        // Authenticated route group + admin route group: same shape
        // production uses, so the test exercises the real middleware
        // stack rather than a parallel implementation.
        let authenticated = api.grouped(
            AuthMiddleware(sessionTTLDays: sessionTTLDays)
        )
        let admin = authenticated.grouped(RoleMiddleware.requireAdmin())

        let usersController = UsersController(
            publicBaseURL: publicBaseURL,
            inviteTTLDays: inviteTTLDays
        )
        usersController.register(on: admin.grouped("users"))

        // A canary route on the admin group — gives the role-gating
        // tests a tiny, predictable target to assert 403 against
        // without depending on UsersController's specific behavior.
        admin.get("admin-canary") { _ in HTTPStatus.ok }

        // A canary on the authenticated-only group — same idea, for
        // the "logged-in member sees 200" case.
        authenticated.get("auth-canary") { _ in HTTPStatus.ok }

        return app
    }

    // MARK: - Setup helpers
    //
    // These compress the "build app → POST setup → grab cookie" ritual
    // that prefaces almost every test into one line. Tests focus on
    // what's unique (the actual assertion) instead of repeating the
    // ritual.

    /// Posts /auth/setup with a fresh admin and returns the resulting
    /// session cookie. The app already has the seeded admin row.
    static func setupAdmin(
        on app: Application,
        email: String = "admin@test.local",
        password: String = "admin-password-12"
    ) async throws -> String {
        var cookie: String?
        try await app.test(
            .POST, "/api/v1/auth/setup",
            beforeRequest: { req in
                try req.content.encode(["email": email, "password": password])
            },
            afterResponse: { res async in
                cookie = res.headers.setCookie?[SessionCookie.name]?.string
            }
        )
        guard let token = cookie else {
            // swift-testing's #require is a macro that only works
            // inside @Test functions; for helpers throw a typed
            // error the test can attribute.
            throw AuthTestAppError.setupNoCookie
        }
        return token
    }

    /// `Cookie:` header containing the session token, ready to drop
    /// into XCTVapor's `headers:` parameter.
    static func cookieHeaders(_ token: String) -> HTTPHeaders {
        ["Cookie": "\(SessionCookie.name)=\(token)"]
    }
}

enum AuthTestAppError: Error, CustomStringConvertible {
    case setupNoCookie

    var description: String {
        switch self {
        case .setupNoCookie:
            return "POST /auth/setup did not return a session cookie"
        }
    }
}
