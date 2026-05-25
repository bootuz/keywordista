import Fluent
import Vapor

/// An operator-controlled user of a Keywordista deployment.
///
/// In server mode (`KEYWORDISTA_MODE=server`) every authenticated
/// request is tied to one of these rows; in local mode the table
/// exists but is empty (no auth middleware ever queries it).
///
/// Tenancy: there's deliberately no `teamId` here. Per plan §4.2,
/// **one team per deployment** — the deployment IS the tenant
/// boundary. Every user in a deployment can see every other user's
/// tracked apps and keywords; only admins can change shared
/// settings (ASC keys, ASA secret) and invite or remove members.
///
/// Adding a third role (e.g. `.viewer` read-only) is SemVer-additive
/// because `Role` is stored as a string column — new cases append
/// to the enum without a schema migration.
final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?

    /// Always stored lowercased + trimmed. The init normalizes on
    /// the way in; the manifest's email parser does the same on the
    /// way IN to the env (admin bootstrap path). Together that means
    /// `you@Studio.com` and `  you@studio.com ` resolve to the same
    /// row, which is the only sane reading of email semantics.
    @Field(key: "email") var email: String

    /// bcrypt MCF string (`$2b$12$…`). We never store plaintext
    /// passwords — even at runtime — anywhere outside the verify call.
    @Field(key: "password_hash") var passwordHash: String

    /// `.admin` can change settings + invite/remove users.
    /// `.member` can do everything else. Stored as a string so adding
    /// roles later is purely additive.
    @Field(key: "role") var role: Role

    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    /// nil until the user successfully logs in for the first time.
    /// Updated by AuthController.login on each successful session
    /// creation. Useful for UI ("teammate hasn't logged in for 90
    /// days — consider revoking?") and forthcoming retention reports.
    @OptionalField(key: "last_login_at") var lastLoginAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        passwordHash: String,
        role: Role,
        createdAt: Date? = nil,
        lastLoginAt: Date? = nil
    ) {
        self.id = id
        // Normalize defensively — duplicate of the manifest's
        // Parsers.email logic. Belt-and-suspenders against future
        // callers that skip the parser.
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.passwordHash = passwordHash
        self.role = role
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }

    // MARK: Role

    enum Role: String, Codable, Sendable, CaseIterable {
        case admin
        case member

        /// `true` if this role has admin privileges. Single helper so
        /// new admin-class roles in the future (`.owner`, `.superadmin`)
        /// can opt in via this property without every call-site
        /// updating its `== .admin` checks.
        var isAdmin: Bool {
            switch self {
            case .admin: return true
            case .member: return false
            }
        }
    }
}

// MARK: - Migration

/// Initial users table. The first user is created either by
/// AuthController.setup (the in-browser wizard) or by the pre-baked
/// admin bootstrap path that reads KEYWORDISTA_ADMIN_EMAIL +
/// KEYWORDISTA_ADMIN_PASSWORD_HASH from the env at boot.
///
/// `email` is unique. Fluent's portable `.unique(on:)` constraint
/// gives us uniqueness on both SQLite and Postgres via the §4.10
/// DatabaseProvider abstraction. SQLite's uniqueness is
/// case-sensitive by default but we normalize in `User.init` so
/// `You@studio.com` and `you@studio.com` are byte-identical before
/// they ever hit the DB.
struct CreateUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("last_login_at", .datetime)
            .unique(on: "email")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
