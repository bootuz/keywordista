import Foundation
import Vapor

/// Route-group middleware that gates downstream handlers on the
/// authenticated user's role. Composes after `AuthMiddleware` —
/// requires `request.auth.require(User.self)` to succeed, so it
/// throws 401 (not 403) if the user isn't even signed in. 403 is
/// reserved for "you're signed in, but you don't have the role
/// this endpoint requires."
///
/// API:
///   `RoleMiddleware(allow: .admin)`          // admin-only
///   `RoleMiddleware(allow: .admin, .member)` // either (redundant
///                                              // with no role
///                                              // middleware, but
///                                              // explicit)
///
/// Why a Set + variadic init: the v1 only-two-roles case looks
/// over-engineered, but it sets up the future "viewer" or "owner"
/// roles to be allow-listed naturally without rewriting every
/// admin-gate as `if role == .admin || role == .owner`. New role
/// = additive change in one spot per route, not per call-site.
struct RoleMiddleware: AsyncMiddleware {

    let allowed: Set<User.Role>

    init(allow roles: User.Role...) {
        self.allowed = Set(roles)
    }

    init(allow allowed: Set<User.Role>) {
        self.allowed = allowed
    }

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        // require(User.self) throws .unauthorized if the user
        // wasn't logged in by an upstream middleware. Per the file
        // header, we want that to surface as 401 not 403 — so we
        // let it propagate verbatim.
        let user = try request.auth.require(User.self)

        guard allowed.contains(user.role) else {
            let names = allowed.map(\.rawValue).sorted().joined(separator: ", ")
            throw Abort(.forbidden, reason: "requires one of: \(names)")
        }

        return try await next.respond(to: request)
    }

    /// Pre-baked convenience for the most common case.
    static func requireAdmin() -> RoleMiddleware {
        RoleMiddleware(allow: .admin)
    }
}
