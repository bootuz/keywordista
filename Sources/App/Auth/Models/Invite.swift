import Crypto
import Fluent
import Foundation
import Vapor

/// A single-use, time-limited invitation for a new user to join a
/// Keywordista deployment.
///
/// Two flavors:
///   • **Email-pinned** invite — `email` set at creation time. The
///     accept flow requires the recipient to use exactly that email.
///     Tighter; appropriate when the admin knows who the invite is for.
///   • **Open** invite — `email = nil`. Anyone in possession of the
///     token can accept it; the acceptance flow lets the recipient
///     pick any email. Useful for "drop this link in our team Slack,
///     first taker wins."
///
/// Lifecycle:
///   1. Admin posts to /api/v1/users/invite → row created with a fresh
///      token + expiresAt = now + inviteTTLDays.
///   2. Recipient visits /#/invite/<token> → AuthController fetches
///      the row, checks not expired, not consumed.
///   3. Recipient sets a password → AuthController creates a new User,
///      marks the invite consumed (consumedAt + consumedBy).
///   4. Token is now invalid for any future use (consumed_at non-nil).
///
/// Created_by → ON DELETE CASCADE: if the admin who created this invite
/// is deleted, the invite dies with them (nobody can vouch for a
/// token whose origin is gone).
///
/// Consumed_by → ON DELETE SET NULL: if the user who accepted is later
/// deleted, the invite row stays (historical record that the invite
/// WAS accepted on date X) but the pointer to the specific user
/// becomes null.
final class Invite: Model, @unchecked Sendable {
    static let schema = "auth_invites"

    @ID(key: .id) var id: UUID?

    /// Optional pre-pin: when set, the accept flow requires the
    /// recipient to use this exact email. Normalized to lowercased +
    /// trimmed in init for the same reason User.email is — case
    /// shouldn't cause the accept flow to reject a legitimate match.
    @OptionalField(key: "email") var email: String?

    /// Role the new User will be granted on acceptance.
    @Field(key: "role") var role: User.Role

    /// 256-bit random base64url, 43 chars. Same shape as
    /// AuthSession.token; if we add a third caller for the same
    /// pattern (e.g. forgot-password tokens) we'll factor out a
    /// shared Tokens utility — not worth the indirection for 2.
    @Field(key: "token") var token: String

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    @Field(key: "expires_at") var expiresAt: Date

    /// nil until the invite is accepted.
    @OptionalField(key: "consumed_at") var consumedAt: Date?

    /// nil until accepted; nil again if the consuming user is later
    /// deleted (FK ON DELETE SET NULL).
    @OptionalParent(key: "consumed_by_user_id") var consumedBy: User?

    /// The admin who created this invite. Required at insert; row
    /// CASCADEs on the admin's deletion.
    @Parent(key: "created_by_user_id") var createdBy: User

    init() {}

    /// Convenience for the admin "create invite" path. Generates a
    /// fresh token and computes expiresAt from the TTL; caller
    /// supplies role + admin's ID + (optional) email pre-pin.
    convenience init(
        role: User.Role,
        email: String? = nil,
        createdByID: UUID,
        ttlDays: Int
    ) {
        self.init()
        self.role = role
        self.email = email.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.token = Self.generateToken()
        self.expiresAt = Self.expiry(fromNow: ttlDays)
        self.$createdBy.id = createdByID
    }

    /// Designated init for tests + fixtures — pins every field.
    init(
        id: UUID? = nil,
        email: String? = nil,
        role: User.Role,
        token: String,
        createdAt: Date? = nil,
        expiresAt: Date,
        consumedAt: Date? = nil,
        consumedByID: UUID? = nil,
        createdByID: UUID
    ) {
        self.id = id
        self.email = email.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        self.role = role
        self.token = token
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.$consumedBy.id = consumedByID
        self.$createdBy.id = createdByID
    }

    // MARK: - Token + expiry helpers

    /// 256 bits secure random → base64url(no padding). Duplicates
    /// AuthSession.generateToken — see model header for the
    /// "why not refactor" rationale.
    static func generateToken() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).base64URLEncodedString() }
    }

    static func expiry(fromNow ttlDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(ttlDays) * 86_400)
    }

    // MARK: - Lifecycle

    /// `true` iff `expiresAt` is in the past at the given reference
    /// time. Mirror of AuthSession.isExpired so the auth layer has
    /// one mental model for "stale token."
    func isExpired(at reference: Date = Date()) -> Bool {
        expiresAt <= reference
    }

    /// `true` iff this invite has already been accepted.
    var isConsumed: Bool {
        consumedAt != nil
    }

    /// Mark the invite as consumed by `userID` at `at`. Doesn't
    /// persist — caller is responsible for `invite.save(on:)`.
    /// Idempotent: calling consume on an already-consumed invite
    /// updates the timestamps (callers should check `isConsumed`
    /// first if they want the first-write-wins semantic).
    func consume(by userID: UUID, at: Date = Date()) {
        self.consumedAt = at
        self.$consumedBy.id = userID
    }
}

// MARK: - Migration

/// Initial auth_invites table.
///
/// Constraints:
///   • token unique — same defense-in-depth as auth_sessions; the
///     256-bit space makes collisions astronomical, but the unique
///     constraint guarantees no silent cross-invite confusion.
///   • created_by_user_id ON DELETE CASCADE — see model header.
///   • consumed_by_user_id ON DELETE SET NULL — see model header.
///   • Index on expires_at for the eventual sweep (future M-level
///     "purge expired invites" job; not in v1 since the table grows
///     slowly enough that manual cleanup is fine).
struct CreateInvites: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Invite.schema)
            .id()
            .field("email", .string)
            .field("role", .string, .required)
            .field("token", .string, .required)
            .field("created_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("consumed_by_user_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_by_user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .unique(on: "token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Invite.schema).delete()
    }
}

// MARK: - base64url
//
// Same one-method extension AuthSession defines. Swift's
// fileprivate-vs-internal mechanics let both files declare the
// extension without collision (each is scoped to its own file).
// Factor out if a third caller appears.

private extension Data {
    /// RFC 4648 §5: URL-safe base64 with `-` and `_`, no padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
