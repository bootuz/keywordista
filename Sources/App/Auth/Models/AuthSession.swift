import Crypto
import Fluent
import Foundation
import Vapor

/// A long-lived authenticated session for a `User`.
///
/// Why not Vapor's built-in SessionsMiddleware: we want full control
/// over the token format (256-bit, base64url, indexed for O(log n)
/// lookup), the rolling-TTL semantics (`expiresAt` slides forward on
/// each request, not just a `lastAccess` field), per-session
/// `userAgent` capture, and clean operation under our §4.10
/// DatabaseProvider abstraction (one table; same shape on SQLite +
/// Postgres). Building it ourselves is ~150 LOC and removes a
/// dependency the auth flow doesn't need.
///
/// Named `AuthSession` (not bare `Session`) to avoid shadowing
/// Vapor's public `Session` type, which would force every
/// `import Vapor` call-site to disambiguate.
///
/// Lifecycle:
///   • AuthController.login creates one with a fresh token + initial
///     expiresAt = now + sessionTTLDays.
///   • AuthMiddleware looks it up by token on each request, rejects
///     if expiresAt has passed, slides expiresAt forward by
///     sessionTTLDays otherwise.
///   • AuthController.logout deletes it.
///   • configure.swift purges expired rows at boot (see
///     `purgeExpired(on:)` below) so the table doesn't grow
///     unbounded with abandoned sessions from forgotten devices.
final class AuthSession: Model, @unchecked Sendable {
    static let schema = "auth_sessions"

    @ID(key: .id) var id: UUID?

    /// The user this session authenticates. Fluent's `@Parent`
    /// emits a foreign-key column `user_id`; cascading delete is
    /// set on the migration so deleting a user clears their
    /// sessions atomically.
    @Parent(key: "user_id") var user: User

    /// 256 bits of cryptographically secure random, base64url-
    /// encoded (no padding). 43 ASCII chars. Indexed because every
    /// authenticated request looks the session up by this column.
    @Field(key: "token") var token: String

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    /// Sliding expiry. AuthMiddleware updates this on each request:
    ///   session.expiresAt = Date().addingTimeInterval(ttl)
    @Field(key: "expires_at") var expiresAt: Date

    /// Captured at login. Surfaced in the eventual "active sessions"
    /// admin UI ("logged in from Safari on macOS"). Optional because
    /// some clients (curl, scripts) don't send one.
    @OptionalField(key: "user_agent") var userAgent: String?

    init() {}

    /// Convenience for the AuthController.login path. Generates a
    /// fresh token and computes expiresAt from the TTL; caller just
    /// supplies the user and (optionally) the request's User-Agent.
    /// Marked `convenience` because it delegates to `init()` to
    /// satisfy Fluent's empty-init requirement and then sets the
    /// fields — Swift forbids `self.init` from non-convenience inits.
    convenience init(userID: UUID, ttlDays: Int, userAgent: String? = nil) {
        self.init()
        self.$user.id = userID
        self.token = Self.generateToken()
        self.expiresAt = Self.expiry(fromNow: ttlDays)
        self.userAgent = userAgent
    }

    /// Designated init for tests + migrations — lets callers pin every
    /// field including the token (for assertion-friendly fixtures).
    init(
        id: UUID? = nil,
        userID: UUID,
        token: String,
        createdAt: Date? = nil,
        expiresAt: Date,
        userAgent: String? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.userAgent = userAgent
    }

    // MARK: - Token generation

    /// 256 bits of secure random → base64url(no padding) → 43 chars.
    /// Backed by Swift Crypto's `SymmetricKey(size:)`, which sources
    /// from arc4random_buf on Apple and /dev/urandom on Linux.
    static func generateToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).base64URLEncodedString() }
    }

    /// `expiresAt = now + ttlDays`, factored out so tests can
    /// reproduce the math without poking at Date math directly.
    static func expiry(fromNow ttlDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(ttlDays) * 86_400)
    }

    // MARK: - Lifecycle helpers

    /// `true` iff `expiresAt` is in the past at the given reference
    /// time (default `Date()`). Pure function for testability.
    func isExpired(at reference: Date = Date()) -> Bool {
        expiresAt <= reference
    }

    /// Slide `expiresAt` forward by `ttlDays` (rolling-TTL).
    /// Doesn't persist — caller is responsible for `session.save(on:)`.
    func extend(ttlDays: Int, now: Date = Date()) {
        expiresAt = Self.expiry(fromNow: ttlDays, now: now)
    }

    /// Boot-time housekeeping: DELETE all rows whose expiresAt is
    /// in the past. Called from configure.swift right after migrations
    /// run. Returns the number of rows deleted (informational; logged
    /// at info level for ops visibility).
    static func purgeExpired(on db: any Database, now: Date = Date()) async throws -> Int {
        let expired = try await AuthSession.query(on: db)
            .filter(\.$expiresAt <= now)
            .all()
        let count = expired.count
        try await AuthSession.query(on: db)
            .filter(\.$expiresAt <= now)
            .delete()
        return count
    }
}

// MARK: - Migration

/// Initial auth_sessions table. Cascading delete on user_id so that
/// deleting a User row (admin removes a teammate) drops all their
/// active sessions in one statement — no need for a service-layer
/// "delete user → loop sessions" dance.
///
/// Unique constraint on `token`: defense in depth. The 256-bit
/// random space makes collisions astronomically improbable, but the
/// unique constraint guarantees that a hash collision can never
/// silently authenticate the wrong user.
///
/// Index on `expires_at` for the boot-time purgeExpired sweep —
/// SQLite/Postgres both pick it up via `.unique`/`.index` schema
/// methods.
struct CreateAuthSessions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AuthSession.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token", .string, .required)
            .field("created_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("user_agent", .string)
            .unique(on: "token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AuthSession.schema).delete()
    }
}

// MARK: - base64url

private extension Data {
    /// RFC 4648 §5: URL-safe base64 with `-` and `_`, no padding.
    /// Used here for session tokens + (in M1.4) invite tokens.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
