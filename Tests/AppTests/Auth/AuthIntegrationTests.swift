@testable import App
import Fluent
import Foundation
import Testing
import Vapor
import XCTVapor

/// Real-HTTP integration tests for M1's auth + admin surface.
///
/// Each test spins up a fresh Vapor Application via `AuthTestApp.make()`
/// — in-memory SQLite, all auth migrations run, all routes registered
/// behind the real AuthMiddleware + RoleMiddleware. Tests hit the
/// running app with XCTVapor's `app.test(.METHOD, path)` and assert
/// on real HTTP responses + cookies.
///
/// **What's covered here that the unit tests can't reach**:
///   • The auth middleware ACTUALLY rejecting requests without a
///     session cookie at the HTTP layer (not just "it throws Abort").
///   • Set-Cookie response headers carrying the right flags + value.
///   • Session round-trip: a cookie issued by /auth/setup actually
///     lets you reach /auth-canary on the next request.
///   • Role gating: 403 when a member hits an admin endpoint.
///   • Invite single-use enforcement at the controller layer.
///
/// **bcrypt cost is 4** for the test app (AuthTestApp.bcryptCost) so
/// the suite runs in seconds, not minutes.
@Suite("Auth integration (M1.12)")
struct AuthIntegrationTests {

    // ── /auth/setup ──────────────────────────────────────────────────

    @Suite("/auth/setup")
    struct SetupTests {

        @Test("POST /auth/setup creates the admin + returns a session cookie")
        func happyPath() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }

            try await app.test(
                .POST, "/api/v1/auth/setup",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "founder@studio.local",
                        "password": "very-strong-pw-please",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .created)
                    let cookie = res.headers.setCookie?[SessionCookie.name]
                    #expect(cookie != nil, "expected Set-Cookie with the session token")
                    #expect(cookie?.isHTTPOnly == true)
                    #expect(cookie?.isSecure == true)
                    #expect(cookie?.sameSite == .strict)
                }
            )

            // And the user landed in the DB with role=.admin.
            let users = try await User.query(on: app.db).all()
            #expect(users.count == 1)
            #expect(users.first?.email == "founder@studio.local")
            #expect(users.first?.role == .admin)
        }

        @Test("POST /auth/setup returns 410 if any user already exists")
        func doubleSetupIs410() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .POST, "/api/v1/auth/setup",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "second@studio.local",
                        "password": "another-strong-pw",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .gone)
                }
            )

            // And the second setup attempt did NOT create a user.
            let count = try await User.query(on: app.db).count()
            #expect(count == 1)
        }

        @Test("Setup rejects too-short passwords (manifest min length)")
        func rejectsShortPassword() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }

            try await app.test(
                .POST, "/api/v1/auth/setup",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "founder@studio.local",
                        "password": "short",     // 5 chars; min is 8
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .badRequest)
                }
            )
        }
    }

    // ── /auth/login + /auth/logout ───────────────────────────────────

    @Suite("/auth/login + /auth/logout")
    struct LoginLogoutTests {

        @Test("Correct credentials return 200 + session cookie")
        func loginHappy() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(
                on: app,
                email: "alice@studio.local",
                password: "alice-secret-12"
            )

            try await app.test(
                .POST, "/api/v1/auth/login",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "alice@studio.local",
                        "password": "alice-secret-12",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.setCookie?[SessionCookie.name] != nil)
                }
            )
        }

        @Test("Wrong password returns generic 401 (no account enumeration)")
        func wrongPasswordIs401() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(
                on: app,
                email: "alice@studio.local",
                password: "alice-secret-12"
            )

            try await app.test(
                .POST, "/api/v1/auth/login",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "alice@studio.local",
                        "password": "wrong-password-x",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                }
            )
        }

        @Test("Unknown user returns the same 401 as wrong password (constant-time)")
        func unknownUserSameError() async throws {
            // Critical security property: the response status (and
            // ideally response time) must NOT reveal whether the email
            // is registered. AuthController's decoy-hash trick handles
            // the timing; this test pins the status equality.
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .POST, "/api/v1/auth/login",
                beforeRequest: { req in
                    try req.content.encode([
                        "email": "ghost@studio.local",   // never registered
                        "password": "12345678",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .unauthorized)
                }
            )
        }

        @Test("Logout DELETEs the session row + clears the cookie")
        func logoutClearsState() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let cookie = try await AuthTestApp.setupAdmin(on: app)

            // Sanity: the session row exists.
            let beforeCount = try await AuthSession.query(on: app.db).count()
            #expect(beforeCount == 1)

            try await app.test(
                .POST, "/api/v1/auth/logout",
                headers: AuthTestApp.cookieHeaders(cookie),
                afterResponse: { res async in
                    #expect(res.status == .noContent)
                    // Set-Cookie should send an "empty value, epoch-zero
                    // expiry" cookie so the browser drops it.
                    let cleared = res.headers.setCookie?[SessionCookie.name]
                    #expect(cleared?.string == "")
                }
            )

            // And the DB row is gone.
            let afterCount = try await AuthSession.query(on: app.db).count()
            #expect(afterCount == 0)
        }
    }

    // ── /auth/state ──────────────────────────────────────────────────

    @Suite("/auth/state")
    struct StateTests {

        @Test("Returns firstRun=true / signedIn=false on a freshly-set-up empty app")
        func freshAppShowsFirstRun() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }

            try await app.test(
                .GET, "/api/v1/auth/state",
                afterResponse: { res async in
                    #expect(res.status == .ok)
                    let body = try? res.content.decode(AuthStateResponse.self)
                    #expect(body?.firstRun == true)
                    #expect(body?.signedIn == false)
                    #expect(body?.user == nil)
                }
            )
        }

        @Test("After setup + with valid cookie, returns firstRun=false / signedIn=true")
        func afterSetupWithCookie() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let cookie = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .GET, "/api/v1/auth/state",
                headers: AuthTestApp.cookieHeaders(cookie),
                afterResponse: { res async in
                    let body = try? res.content.decode(AuthStateResponse.self)
                    #expect(body?.firstRun == false)
                    #expect(body?.signedIn == true)
                    #expect(body?.user?.role == "admin")
                }
            )
        }

        @Test("After setup, no cookie → firstRun=false / signedIn=false")
        func afterSetupWithoutCookie() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .GET, "/api/v1/auth/state",
                afterResponse: { res async in
                    let body = try? res.content.decode(AuthStateResponse.self)
                    #expect(body?.firstRun == false)
                    #expect(body?.signedIn == false)
                }
            )
        }
    }

    // ── AuthMiddleware via canary route ──────────────────────────────

    @Suite("AuthMiddleware")
    struct AuthMiddlewareTests {

        @Test("Authenticated route returns 401 with no cookie")
        func noCookieIs401() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(.GET, "/api/v1/auth-canary") { res async in
                #expect(res.status == .unauthorized)
            }
        }

        @Test("Garbage cookie value returns 401 (no matching session row)")
        func garbageCookieIs401() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .GET, "/api/v1/auth-canary",
                headers: AuthTestApp.cookieHeaders("not-a-real-token-at-all-xxxxxxxxxxxxxxxxxxx")
            ) { res async in
                #expect(res.status == .unauthorized)
            }
        }

        @Test("Valid cookie reaches the authenticated route (returns 200)")
        func validCookiePasses() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let cookie = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .GET, "/api/v1/auth-canary",
                headers: AuthTestApp.cookieHeaders(cookie)
            ) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    // ── RoleMiddleware via canary route ──────────────────────────────

    @Suite("RoleMiddleware")
    struct RoleMiddlewareTests {

        @Test("Admin user reaches the admin-canary (200)")
        func adminReaches() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let cookie = try await AuthTestApp.setupAdmin(on: app)

            try await app.test(
                .GET, "/api/v1/admin-canary",
                headers: AuthTestApp.cookieHeaders(cookie)
            ) { res async in
                #expect(res.status == .ok)
            }
        }

        @Test("Member hitting admin-canary gets 403")
        func memberGets403() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            // Manually create a member User + session — bypassing the
            // invite flow because that's a different test suite.
            let hasher = try PasswordHasher(cost: AuthTestApp.bcryptCost)
            let member = User(
                email: "member@studio.local",
                passwordHash: try await hasher.hash("member-pw-12"),
                role: .member
            )
            try await member.save(on: app.db)
            let session = AuthSession(userID: try member.requireID(), ttlDays: 30)
            try await session.save(on: app.db)

            try await app.test(
                .GET, "/api/v1/admin-canary",
                headers: AuthTestApp.cookieHeaders(session.token)
            ) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    // ── Invite flow ──────────────────────────────────────────────────

    @Suite("Invite + accept")
    struct InviteTests {

        @Test("Admin POSTs an invite, recipient accepts, account is created")
        func happyPath() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let adminCookie = try await AuthTestApp.setupAdmin(on: app)

            // Step 1: admin creates an open invite.
            var inviteToken: String?
            try await app.test(
                .POST, "/api/v1/users/invite",  // admin.users prefix
                headers: AuthTestApp.cookieHeaders(adminCookie),
                beforeRequest: { req in
                    try req.content.encode(["role": "member"])
                },
                afterResponse: { res async in
                    #expect(res.status == .created)
                    let body = try? res.content.decode(InviteCreatedResponse.self)
                    inviteToken = body?.token
                }
            )

            guard let token = inviteToken else {
                Issue.record("invite endpoint didn't return a token"); return
            }

            // Step 2: recipient accepts. (Open invite → must supply email.)
            try await app.test(
                .POST, "/api/v1/auth/accept-invite",
                beforeRequest: { req in
                    try req.content.encode([
                        "token": token,
                        "password": "newbie-password-12",
                        "email": "newbie@studio.local",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .created)
                    #expect(res.headers.setCookie?[SessionCookie.name] != nil)
                }
            )

            // And a new User row exists with role=.member.
            let users = try await User.query(on: app.db)
                .filter(\.$email == "newbie@studio.local")
                .all()
            #expect(users.count == 1)
            #expect(users.first?.role == .member)
        }

        @Test("Accepting an already-consumed invite returns 409")
        func alreadyConsumed() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            let adminCookie = try await AuthTestApp.setupAdmin(on: app)

            var token: String?
            try await app.test(
                .POST, "/api/v1/users/invite",
                headers: AuthTestApp.cookieHeaders(adminCookie),
                beforeRequest: { req in
                    try req.content.encode(["role": "member"])
                },
                afterResponse: { res async in
                    token = (try? res.content.decode(InviteCreatedResponse.self))?.token
                }
            )

            // First acceptance — succeeds.
            try await app.test(
                .POST, "/api/v1/auth/accept-invite",
                beforeRequest: { req in
                    try req.content.encode([
                        "token": token!,
                        "password": "first-attempt-12",
                        "email": "first@studio.local",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .created)
                }
            )

            // Second acceptance with the same token — 409.
            try await app.test(
                .POST, "/api/v1/auth/accept-invite",
                beforeRequest: { req in
                    try req.content.encode([
                        "token": token!,
                        "password": "second-attempt-12",
                        "email": "second@studio.local",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .conflict)
                }
            )
        }

        @Test("Accepting an unknown token returns 404")
        func unknownTokenIs404() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            // Real-shape token (43 chars base64url) so the input
            // validator doesn't reject it as malformed first.
            let fakeToken = Invite.generateToken()
            try await app.test(
                .POST, "/api/v1/auth/accept-invite",
                beforeRequest: { req in
                    try req.content.encode([
                        "token": fakeToken,
                        "password": "any-password-12",
                        "email": "nobody@studio.local",
                    ])
                },
                afterResponse: { res async in
                    #expect(res.status == .notFound)
                }
            )
        }

        @Test("Member can't create invites (admin-only)")
        func memberCantInvite() async throws {
            let app = try await AuthTestApp.make()
            defer { Task { try? await app.asyncShutdown() } }
            _ = try await AuthTestApp.setupAdmin(on: app)

            // Create a member directly.
            let hasher = try PasswordHasher(cost: AuthTestApp.bcryptCost)
            let member = User(
                email: "member@studio.local",
                passwordHash: try await hasher.hash("member-pw-12"),
                role: .member
            )
            try await member.save(on: app.db)
            let session = AuthSession(userID: try member.requireID(), ttlDays: 30)
            try await session.save(on: app.db)

            try await app.test(
                .POST, "/api/v1/users/invite",
                headers: AuthTestApp.cookieHeaders(session.token),
                beforeRequest: { req in
                    try req.content.encode(["role": "member"])
                },
                afterResponse: { res async in
                    #expect(res.status == .forbidden)
                }
            )
        }
    }
}
