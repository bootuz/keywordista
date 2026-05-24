import Fluent
import Foundation
import Vapor

/// Verifies the session cookie, looks up the User, and attaches it to
/// `request.auth`. Applied as a route-group middleware on every
/// authenticated route in server mode; never applied in local mode.
///
/// Lifecycle of a request that passes through:
///   1. Read `keywordista_session` cookie → throw 401 if missing.
///   2. Query `AuthSession` by token → throw 401 if not found.
///   3. Check `isExpired()` → throw 401 + best-effort DELETE the
///      expired row so it doesn't linger in the table.
///   4. Load the User row → throw 401 if missing (corrupt state:
///      session points at a deleted user; treat the same as a
///      stale cookie).
///   5. **Slide the rolling TTL**: extend `expiresAt` forward by
///      `sessionTTLDays` so an active user stays logged in
///      indefinitely. Idle users naturally age out.
///   6. `request.auth.login(user)` so downstream handlers can call
///      `req.auth.require(User.self)`.
///   7. Continue to the next responder.
///
/// **Rolling-TTL trade-off**: extending on every request means an
/// active user never logs out involuntarily, but a stolen token also
/// stays alive for `sessionTTLDays` past the theft window. The
/// operator-controlled `KEYWORDISTA_SESSION_TTL_DAYS` env var
/// (default 30) is the dial — shorter = tighter security, longer =
/// less "you've been logged out" friction.
///
/// **Why this middleware doesn't refresh the Set-Cookie header**:
/// the browser cookie was set at login with the full TTL. The
/// server can extend the row's expiresAt forward without re-sending
/// the cookie; the browser keeps the same cookie value, and the
/// server keeps accepting it. If we ever want the cookie's *browser-
/// side* expiry to slide too, we'd set a fresh Set-Cookie on each
/// response — for v1, skip (Set-Cookie on every request adds
/// per-request overhead for marginal UX gain).
struct AuthMiddleware: AsyncMiddleware {

    let sessionTTLDays: Int

    init(sessionTTLDays: Int) {
        self.sessionTTLDays = sessionTTLDays
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        guard let token = request.cookies[SessionCookie.name]?.string, !token.isEmpty else {
            throw Abort(.unauthorized, reason: "not signed in")
        }

        guard let session = try await AuthSession.query(on: request.db)
            .filter(\.$token == token)
            .first()
        else {
            throw Abort(.unauthorized, reason: "session not found")
        }

        if session.isExpired() {
            // Best-effort cleanup. If the delete fails (DB contention,
            // race with the boot-time purge sweep) we don't care —
            // the next boot will sweep it.
            try? await session.delete(on: request.db)
            throw Abort(.unauthorized, reason: "session expired")
        }

        guard let user = try await User.find(session.$user.id, on: request.db) else {
            // Session points at a deleted user. Treat as a stale
            // cookie; cleanup the orphan session too.
            try? await session.delete(on: request.db)
            throw Abort(.unauthorized, reason: "session is no longer valid")
        }

        // Rolling-TTL extension — see header comment for trade-off.
        session.extend(ttlDays: sessionTTLDays)
        try await session.save(on: request.db)

        request.auth.login(user)
        return try await next.respond(to: request)
    }
}

// MARK: - User: Authenticatable

/// Vapor's `Authenticatable` is a marker protocol — no requirements,
/// it just lets `req.auth.login(_:)` and `req.auth.require(_:)` see
/// the type. Conformance lives in this file (not Models/User.swift)
/// because it's *Vapor-shaped*, not User-shaped: a model file
/// shouldn't have to know about Vapor's auth machinery.
extension User: Authenticatable {}
