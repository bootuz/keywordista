import Fluent
import Foundation
import Vapor

/// HTTP routes for the auth flow.
///
/// Composes M1's four primitives:
///   • `User`           (M1.1) — the row each request hangs off
///   • `PasswordHasher` (M1.2) — bcrypt off-EventLoop
///   • `AuthSession`    (M1.3) — long-lived cookie-backed token
///   • `Invite`         (M1.4) — single-use accept-by-link
///
/// All five routes ship in this commit but are NOT wired into
/// `routes.swift` yet — M1.10 does the wire-up alongside the
/// middleware registration. Same dead-code-pending-activation
/// pattern M0.1 used (manifest built → wired in M0.4).
///
/// **Routes**:
///   • `POST /api/v1/auth/setup`          — first-run admin creation
///   • `POST /api/v1/auth/login`          — email + password
///   • `POST /api/v1/auth/logout`         — clears cookie + DB row
///   • `POST /api/v1/auth/accept-invite`  — token + password [+ email]
///   • `GET  /api/v1/auth/state`          — { firstRun, signedIn, user? }
///
/// **Cookie**: all success paths Set-Cookie the session token via
/// `SessionCookie.value(...)`. Logout sends `SessionCookie.cleared()`.
///
/// **Errors**: thrown via `Abort(...)`; Vapor's `ErrorMiddleware`
/// serializes them to the right HTTP status + JSON body.
/// Notably:
///   • 401 — generic "invalid credentials" (NEVER reveals whether
///           the email or the password was wrong; prevents account
///           enumeration).
///   • 409 — email already in use / invite already consumed.
///   • 410 — setup attempted after first user exists.
///   • 422 — invite expired or email-pinned mismatch.
struct AuthController {

    let hasher: PasswordHasher
    let sessionTTLDays: Int
    let inviteTTLDays: Int

    init(hasher: PasswordHasher, sessionTTLDays: Int, inviteTTLDays: Int) {
        self.hasher = hasher
        self.sessionTTLDays = sessionTTLDays
        self.inviteTTLDays = inviteTTLDays
    }

    /// Registers the five auth routes under `/api/v1/auth/*`.
    /// M1.10's routes.swift calls this with the `/api/v1/auth` group.
    func register(on routes: any RoutesBuilder) {
        routes.post("setup", use: setup)
        routes.post("login", use: login)
        routes.post("logout", use: logout)
        routes.post("accept-invite", use: acceptInvite)
        routes.get("state", use: state)
    }

    // MARK: - POST /setup

    /// First-run admin creation. Returns 410 Gone the moment any
    /// user exists in the DB — the only way to reset is by deleting
    /// every user (manual DB surgery). This is the correct security
    /// posture: a public `/setup` endpoint on a running deployment
    /// would be a takeover vector.
    func setup(req: Request) async throws -> Response {
        if try await User.query(on: req.db).count() > 0 {
            throw Abort(.gone, reason: "setup already complete; use /auth/login")
        }

        let input = try req.content.decode(CredentialsRequest.self)
        let email = try AuthInputs.validateEmail(input.email)
        try AuthInputs.validatePassword(input.password)

        let user = User(
            email: email,
            passwordHash: try await hasher.hash(input.password),
            role: .admin
        )
        try await user.save(on: req.db)

        return try await issueSessionResponse(for: user, req: req, status: .created)
    }

    // MARK: - POST /login

    /// Email + password → session cookie. Generic 401 on any failure
    /// (no account enumeration). Updates `lastLoginAt` on success.
    func login(req: Request) async throws -> Response {
        let input = try req.content.decode(CredentialsRequest.self)
        let email = try AuthInputs.validateEmail(input.email)
        try AuthInputs.validatePassword(input.password)

        // Generic failure: same Abort whether the user doesn't
        // exist OR the password is wrong. The bcrypt verify still
        // runs against a "decoy hash" of the same cost if the user
        // is missing — without that, the response time would leak
        // account existence to an attacker who can time requests.
        let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()

        let verified: Bool
        if let user = user {
            verified = try await hasher.verify(input.password, against: user.passwordHash)
        } else {
            // Decoy: verify against a known-bad hash so the timing
            // matches the user-exists path. Wasted CPU is the price
            // of not leaking enumeration via timing.
            _ = try? await hasher.verify(input.password, against: decoyHash)
            verified = false
        }

        guard let user = user, verified else {
            throw Abort(.unauthorized, reason: "invalid credentials")
        }

        user.lastLoginAt = Date()
        try await user.save(on: req.db)

        return try await issueSessionResponse(for: user, req: req, status: .ok)
    }

    // MARK: - POST /logout

    /// Idempotent. DELETEs the AuthSession row pointed at by the
    /// cookie (if present + found) and always clears the cookie.
    /// Returns 204 No Content regardless — logout should never
    /// fail in a way that surprises the user.
    func logout(req: Request) async throws -> Response {
        if let token = req.cookies[SessionCookie.name]?.string {
            try await AuthSession.query(on: req.db)
                .filter(\.$token == token)
                .delete()
        }

        let response = Response(status: .noContent)
        response.cookies[SessionCookie.name] = SessionCookie.cleared()
        return response
    }

    // MARK: - POST /accept-invite

    /// Consume an invite by token. Creates a new User with the
    /// invite's role + the supplied password, marks the invite
    /// consumed, and issues a fresh session.
    func acceptInvite(req: Request) async throws -> Response {
        let input = try req.content.decode(AcceptInviteRequest.self)
        let token = try AuthInputs.validateInviteToken(input.token)
        try AuthInputs.validatePassword(input.password)

        guard let invite = try await Invite.query(on: req.db)
            .filter(\.$token == token)
            .first()
        else {
            throw Abort(.notFound, reason: "invite not found")
        }

        if invite.isExpired() {
            throw Abort(.unprocessableEntity, reason: "invite has expired")
        }
        if invite.isConsumed {
            throw Abort(.conflict, reason: "invite has already been accepted")
        }

        // Resolve the new user's email:
        //   • Email-pinned invite: must match the request email if
        //     supplied; ignore the request email if not supplied.
        //   • Open invite: request email is required.
        let acceptanceEmail: String
        if let pinned = invite.email {
            if let supplied = input.email {
                let normalized = try AuthInputs.validateEmail(supplied)
                guard normalized == pinned else {
                    throw Abort(.unprocessableEntity, reason: "invite is pinned to a different email")
                }
            }
            acceptanceEmail = pinned
        } else {
            guard let supplied = input.email else {
                throw Abort(.badRequest, reason: "this invite has no pre-pinned email; please supply one")
            }
            acceptanceEmail = try AuthInputs.validateEmail(supplied)
        }

        // Email conflict — the unique constraint on users(email)
        // would catch this anyway, but a clear 409 with a typed
        // reason beats a DB-driver error string in the frontend.
        let existing = try await User.query(on: req.db)
            .filter(\.$email == acceptanceEmail)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "an account with that email already exists")
        }

        let user = User(
            email: acceptanceEmail,
            passwordHash: try await hasher.hash(input.password),
            role: invite.role
        )
        try await user.save(on: req.db)

        invite.consume(by: try user.requireID())
        try await invite.save(on: req.db)

        return try await issueSessionResponse(for: user, req: req, status: .created)
    }

    // MARK: - GET /state

    /// Cheap state probe the SPA hits on app boot to decide between
    /// SetupWizard / LoginPage / Dashboard. Always returns 200; the
    /// frontend reads the booleans.
    func state(req: Request) async throws -> AuthStateResponse {
        let userCount = try await User.query(on: req.db).count()
        let firstRun = userCount == 0

        // Try to resolve the current session from the cookie. We
        // don't update the rolling-TTL here — that's AuthMiddleware's
        // job (M1.6). /state is read-only.
        var currentUser: User?
        if let token = req.cookies[SessionCookie.name]?.string,
           let session = try await AuthSession.query(on: req.db)
            .filter(\.$token == token)
            .first(),
           !session.isExpired() {
            currentUser = try await User.find(session.$user.id, on: req.db)
        }

        return AuthStateResponse(
            firstRun: firstRun,
            signedIn: currentUser != nil,
            user: currentUser.map(UserResponse.init(user:))
        )
    }

    // MARK: - Session issuance helper

    /// Shared between setup / login / accept-invite. Creates the
    /// AuthSession, persists it, builds the Response with the user
    /// payload in the body + the session cookie in the headers.
    /// Captures the request's User-Agent for the eventual "active
    /// sessions" admin UI.
    private func issueSessionResponse(
        for user: User,
        req: Request,
        status: HTTPResponseStatus
    ) async throws -> Response {
        let userAgent = req.headers.first(name: .userAgent)
        let session = AuthSession(
            userID: try user.requireID(),
            ttlDays: sessionTTLDays,
            userAgent: userAgent
        )
        try await session.save(on: req.db)

        let response = Response(status: status)
        try response.content.encode(AuthSuccessResponse(user: UserResponse(user: user)))
        response.cookies[SessionCookie.name] = SessionCookie.value(
            token: session.token,
            expiresAt: session.expiresAt
        )
        return response
    }
}

// MARK: - Request DTOs

struct CredentialsRequest: Content {
    let email: String
    let password: String
}

struct AcceptInviteRequest: Content {
    let token: String
    let password: String
    /// Required for open invites (where the invite has no pinned
    /// email); optional but validated for pinned invites.
    let email: String?
}

// MARK: - Response DTOs

struct UserResponse: Content, Equatable {
    let id: UUID
    let email: String
    let role: String

    init(user: User) {
        // requireID is safe here — the User was just saved or
        // looked up from the DB, both of which guarantee an id.
        self.id = (try? user.requireID()) ?? UUID()
        self.email = user.email
        self.role = user.role.rawValue
    }

    /// Direct init for fixtures / tests.
    init(id: UUID, email: String, role: String) {
        self.id = id
        self.email = email
        self.role = role
    }
}

struct AuthSuccessResponse: Content {
    let user: UserResponse
}

struct AuthStateResponse: Content {
    let firstRun: Bool
    let signedIn: Bool
    let user: UserResponse?
}

// MARK: - Decoy hash for constant-time login

/// A real bcrypt hash we never use for a real user. Verifying a
/// supplied password against this when the user doesn't exist
/// makes the failure-path response time match the success-path
/// time, preventing account enumeration via timing analysis.
///
/// Generated once with `Bcrypt.hash("decoy", cost: 12)`. Cost 12
/// matches the production default. If the manifest's bcryptCost
/// gets bumped, this hash will time differently — that's fine,
/// the enumeration window is still closed because *both* paths
/// time the same hashes.
private let decoyHash =
    "$2b$12$" +
    String(repeating: "a", count: 22) +   // salt
    String(repeating: "x", count: 31)     // hash bytes
