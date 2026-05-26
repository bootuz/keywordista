import Fluent
import Foundation
import Vapor

/// Boot-time admin seeder. If KEYWORDISTA_ADMIN_EMAIL and
/// KEYWORDISTA_ADMIN_PASSWORD_HASH are both set in the environment
/// AND the `users` table is empty, creates the first admin user from
/// those env vars BEFORE the HTTP server starts accepting traffic.
///
/// **Why this exists**: cockpit-deployed instances send the admin
/// credentials as env vars, expecting the backend to seed them at
/// boot — no shell access required, no manual CLI step in the deploy
/// flow. This code reads those env vars and inserts the User row
/// before HTTP traffic starts.
///
/// **Pre-M3.25 security framing**: this also closed a takeover hole
/// against the `POST /api/v1/auth/setup` endpoint, which would
/// otherwise have been wide open for scanners during the boot
/// window. M3.25 removed that endpoint entirely (admin creation
/// moved to the `keywordista createsuperuser` CLI), so the framing
/// today is just "cockpit's seamless-deploy mechanism" — the
/// takeover surface is gone at the architectural level.
///
/// **Lifecycle commitment**: this still runs synchronously to
/// completion BEFORE `routes()` is called in configure.swift, for
/// reasons of clarity (operators reading the logs see seeding
/// happen before HTTP starts) even though the security urgency is
/// now lower.
///
/// **What it does NOT do**:
///   • Update an existing admin (we only seed when users table is
///     empty — overwriting an existing admin would be a serious
///     correctness violation)
///   • Validate the email beyond format (AuthInputs.validateEmail
///     enforces format; we don't check deliverability)
///   • Verify the bcrypt hash will work for login (the cost factor
///     matches what Vapor's Bcrypt.verify accepts: $2a$/$2b$/$2y$)
enum AdminBootstrap {

    /// Result returned to configure.swift for logging visibility.
    enum Outcome: Equatable {
        /// Both env vars present + users table empty → admin created.
        case seeded(email: String)
        /// Users already exist → no-op (subsequent boots skip).
        case alreadyHasUsers
        /// Env vars not set → defer to the `keywordista createsuperuser`
        /// CLI subcommand for admin bootstrap (raw-docker path). Local
        /// mode hits this unconditionally (no auth there).
        case envVarsNotProvided
    }

    /// Runs the bootstrap check. Throws on:
    ///   • Email fails AuthInputs.validateEmail (user typo in env)
    ///   • Bcrypt hash format invalid (caller didn't use htpasswd /
    ///     SecretsGenerator output)
    ///   • DB write failure (rare; surfaces as Render deploy failure
    ///     with a clear log line for ops)
    ///
    /// `env` defaults to `.processEnv` for production; tests pass
    /// `.fixture([...])` so they can exercise the bootstrap without
    /// mutating the test process's env vars (which would leak across
    /// concurrently-running tests). The reason this parameter exists
    /// rather than reading the env Manifest was bootstrapped with:
    /// Manifest currently doesn't capture its boot-time env (filed as
    /// a Manifest API cleanup follow-up — would let every require/
    /// optional call share the same env without explicit threading).
    static func run(
        manifest: Manifest,
        env: ManifestEnv = .processEnv,
        on db: any Database,
        logger: Logger
    ) async throws -> Outcome {
        // Idempotency: if anyone has ever signed up, do nothing.
        // Critical that this check happens BEFORE we look at env vars
        // — otherwise a re-deploy that omits the env vars would skip
        // bootstrap on a fresh DB and leave /setup open.
        let userCount = try await User.query(on: db).count()
        guard userCount == 0 else {
            return .alreadyHasUsers
        }

        // Both env vars must be present. If only one is, that's
        // probably a misconfiguration the operator should know about,
        // but we don't fail boot — we just log + defer to the
        // createsuperuser CLI (M3.25).
        guard let email = try manifest.optional(EnvVars.adminEmail, env: env) else {
            if (try? manifest.optional(EnvVars.adminPasswordHash, env: env)) != nil {
                logger.warning("""
                    KEYWORDISTA_ADMIN_PASSWORD_HASH is set but \
                    KEYWORDISTA_ADMIN_EMAIL is missing — admin will NOT \
                    be auto-created. Set both env vars and restart, OR \
                    bootstrap one manually with \
                    `docker exec -it <container> keywordista createsuperuser`.
                    """)
            }
            return .envVarsNotProvided
        }
        guard let passwordHash = try manifest.optional(EnvVars.adminPasswordHash, env: env) else {
            logger.warning("""
                KEYWORDISTA_ADMIN_EMAIL is set but \
                KEYWORDISTA_ADMIN_PASSWORD_HASH is missing — admin will \
                NOT be auto-created. Set both env vars and restart, OR \
                bootstrap one manually with \
                `docker exec -it <container> keywordista createsuperuser`.
                """)
            return .envVarsNotProvided
        }

        // Final-line validation. The manifest's parsers already validated
        // shape (email regex, bcrypt $2x$ prefix), but a typo could
        // still produce nonsense like "admin@" — re-run AuthInputs.
        let normalizedEmail = try AuthInputs.validateEmail(email)

        let user = User(
            email: normalizedEmail,
            passwordHash: passwordHash,
            role: .admin
        )
        try await user.save(on: db)

        logger.notice("""
            seeded admin user '\(normalizedEmail)' from env vars at boot \
            (KEYWORDISTA_ADMIN_EMAIL + KEYWORDISTA_ADMIN_PASSWORD_HASH). \
            Ready to log in.
            """)

        return .seeded(email: normalizedEmail)
    }
}
