import Fluent
import Foundation
import Vapor

/// Admin-only user management.
///
/// All four routes assume both AuthMiddleware AND
/// RoleMiddleware.requireAdmin() are applied upstream (M1.10 wires
/// the group). The handlers themselves don't check for admin —
/// they trust the middleware chain.
///
/// **Routes**:
///   • `GET    /api/v1/users`        — list every user
///   • `POST   /api/v1/users/invite` — create an invite, return URL
///   • `DELETE /api/v1/users/:id`    — revoke (hard delete)
///   • `PATCH  /api/v1/users/:id`    — change role
///
/// **Lockout safeguards (the subtle ones that matter)**:
///   1. Can't delete yourself (the obvious lockout).
///   2. Can't delete the only admin (the subtle lockout — a single
///      admin demoting "for safety" then realizing they can't undo).
///   3. Can't demote the only admin via PATCH for the same reason.
///
/// All three surface as `409 Conflict` with explicit reasons so the
/// admin UI can render them as user-facing messages rather than
/// generic 400s.
///
/// **Hard delete vs soft delete**: v1 uses hard delete + FK cascades
/// (sessions go via M1.3's CASCADE, created invites via M1.4's
/// CASCADE, consumed_by pointers become NULL via SET NULL). Soft
/// delete (a `deactivated_at` column + query filters everywhere) is
/// strictly future-proofing; if audit-trail preservation becomes a
/// real ask, that lands as an additive migration.
struct UsersController {

    let publicBaseURL: URL
    let inviteTTLDays: Int

    init(publicBaseURL: URL, inviteTTLDays: Int) {
        self.publicBaseURL = publicBaseURL
        self.inviteTTLDays = inviteTTLDays
    }

    /// Registers all four routes under the parent group. M1.10's
    /// routes.swift calls this with the `/api/v1/users` group that
    /// already has AuthMiddleware + RoleMiddleware.requireAdmin
    /// applied.
    func register(on routes: any RoutesBuilder) {
        routes.get(use: list)
        routes.post("invite", use: invite)
        routes.delete(":id", use: revoke)
        routes.patch(":id", use: changeRole)
    }

    // MARK: - GET /users

    func list(req: Request) async throws -> [UserListItem] {
        try await User.query(on: req.db)
            .sort(\.$createdAt, .ascending)
            .all()
            .map(UserListItem.init(user:))
    }

    // MARK: - POST /users/invite

    /// Creates a new invite + returns the acceptance URL ONCE. The
    /// admin UI must display + copy the URL immediately; we never
    /// expose the token again (GET /users/invites is intentionally
    /// not in v1 — see § "Future expansion" below).
    func invite(req: Request) async throws -> Response {
        let input = try req.content.decode(InviteCreateRequest.self)
        let role = try parseRole(input.role)
        let pinnedEmail = try input.email.map(AuthInputs.validateEmail)

        let creator = try req.auth.require(User.self)
        let ttl = input.ttlDays ?? inviteTTLDays
        guard ttl > 0 && ttl <= 365 else {
            throw Abort(.badRequest, reason: "ttlDays must be in 1...365")
        }

        let invite = Invite(
            role: role,
            email: pinnedEmail,
            createdByID: try creator.requireID(),
            ttlDays: ttl
        )
        try await invite.save(on: req.db)

        let response = Response(status: .created)
        try response.content.encode(InviteCreatedResponse(
            id: try invite.requireID(),
            token: invite.token,
            acceptUrl: inviteAcceptURL(token: invite.token),
            role: invite.role.rawValue,
            email: invite.email,
            expiresAt: invite.expiresAt
        ))
        return response
    }

    // MARK: - DELETE /users/:id

    /// Hard-delete a user. FK cascades from M1.3 + M1.4 clean up
    /// the sessions and the invites they created. Safeguards:
    ///   • 409 Conflict if target == requester (self-delete)
    ///   • 409 Conflict if target is the only admin (last-admin)
    func revoke(req: Request) async throws -> Response {
        let targetID = try req.parameters.require("id", as: UUID.self)
        let requester = try req.auth.require(User.self)
        let requesterID = try requester.requireID()

        if targetID == requesterID {
            throw Abort(.conflict, reason: "you can't delete yourself")
        }

        guard let target = try await User.find(targetID, on: req.db) else {
            throw Abort(.notFound, reason: "user not found")
        }

        // Last-admin guard: if we're about to delete an admin, make
        // sure another admin will remain.
        if target.role == .admin {
            let adminCount = try await User.query(on: req.db)
                .filter(\.$role == .admin)
                .count()
            if adminCount <= 1 {
                throw Abort(.conflict, reason: "can't delete the only admin")
            }
        }

        try await target.delete(on: req.db)
        return Response(status: .noContent)
    }

    // MARK: - PATCH /users/:id

    /// Change a user's role. Safeguard: 409 Conflict if demoting
    /// the only admin to member.
    func changeRole(req: Request) async throws -> UserListItem {
        let targetID = try req.parameters.require("id", as: UUID.self)
        let input = try req.content.decode(RoleChangeRequest.self)
        let newRole = try parseRole(input.role)

        guard let target = try await User.find(targetID, on: req.db) else {
            throw Abort(.notFound, reason: "user not found")
        }

        // Last-admin guard: if we're demoting an admin to non-admin,
        // make sure another admin remains.
        if target.role == .admin && newRole != .admin {
            let adminCount = try await User.query(on: req.db)
                .filter(\.$role == .admin)
                .count()
            if adminCount <= 1 {
                throw Abort(.conflict, reason: "can't demote the only admin")
            }
        }

        target.role = newRole
        try await target.save(on: req.db)
        return UserListItem(user: target)
    }

    // MARK: - Helpers

    /// Builds the acceptance URL the recipient visits. SPA hash route
    /// because the frontend is a hash-router-based SPA (no SSR).
    /// Examples:
    ///   https://kw.example.com/#/invite/<token>
    ///   http://localhost:8080/#/invite/<token>
    func inviteAcceptURL(token: String) -> URL {
        // Join carefully — URL's appendingPathComponent escapes the
        // '#' character which would break the hash route. Build the
        // string manually instead.
        var base = publicBaseURL.absoluteString
        if base.hasSuffix("/") {
            base.removeLast()
        }
        return URL(string: "\(base)/#/invite/\(token)") ?? publicBaseURL
    }

    private func parseRole(_ raw: String) throws -> User.Role {
        guard let role = User.Role(rawValue: raw.lowercased()) else {
            throw Abort(.badRequest, reason: "role must be one of: \(User.Role.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return role
    }
}

// MARK: - DTOs

struct UserListItem: Content, Equatable {
    let id: UUID
    let email: String
    let role: String
    let createdAt: Date?
    let lastLoginAt: Date?

    init(user: User) {
        self.id = (try? user.requireID()) ?? UUID()
        self.email = user.email
        self.role = user.role.rawValue
        self.createdAt = user.createdAt
        self.lastLoginAt = user.lastLoginAt
    }

    init(id: UUID, email: String, role: String, createdAt: Date?, lastLoginAt: Date?) {
        self.id = id
        self.email = email
        self.role = role
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
    }
}

struct InviteCreateRequest: Content {
    let role: String
    let email: String?
    let ttlDays: Int?
}

struct InviteCreatedResponse: Content {
    let id: UUID
    /// The raw token — shown to the admin ONCE for copy-to-clipboard.
    /// Future GET endpoints intentionally won't return this.
    let token: String
    /// Pre-built acceptance URL the admin sends to the recipient.
    let acceptUrl: URL
    let role: String
    let email: String?
    let expiresAt: Date
}

struct RoleChangeRequest: Content {
    let role: String
}
