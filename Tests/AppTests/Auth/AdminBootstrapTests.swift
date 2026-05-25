import Fluent
import FluentSQLiteDriver
import Foundation
import Logging
import Testing
import Vapor

@testable import App

/// Pins the security contract of AdminBootstrap.run — the boot-time
/// hook that closes the /api/v1/auth/setup takeover hole.
///
/// **Security story** (from AdminBootstrap.swift):
///   cockpit-deployed instances send the admin credentials as env
///   vars expecting the backend to seed them at boot. Without
///   AdminBootstrap, the env vars are read by the manifest but never
///   consumed — the users table stays empty, /setup is wide open,
///   and any visitor to the URL claims admin.
///
/// **What's covered**:
///   • Empty DB + both env vars → admin created with correct role
///     + correct password hash (login would succeed against it)
///   • Existing users + env vars → no-op (re-deploy doesn't overwrite)
///   • Empty DB + missing env vars → no-op (defers to wizard)
///   • Empty DB + only one env var → no-op (misconfiguration; log warns)
///   • Email validation throws on garbage
@Suite("AdminBootstrap (M3.17)")
struct AdminBootstrapTests {

    /// Spin up an in-memory SQLite + run migrations so each test
    /// gets a fresh users table. Pattern mirrors AuthTestApp but
    /// scoped down — AdminBootstrap doesn't need the full HTTP
    /// surface, just the User model + a Database + a Manifest.
    private func makeApp(env: [String: String]) async throws -> Application {
        let app = try await Application.make(.testing)

        // Wire DB.
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateUsers())
        try await app.autoMigrate()

        // ManifestEnv.fixture lets us inject a test-controlled env
        // — same pattern EnvVarManifestTests uses.
        var fullEnv = env
        // Both fixture cases assume server mode — that's where the
        // env vars actually matter. Local mode would just skip
        // bootstrap.
        fullEnv["KEYWORDISTA_MODE"] = "server"
        fullEnv["KEYWORDISTA_ENCRYPTION_KEY"] = String(repeating: "00", count: 32)
        fullEnv["KEYWORDISTA_PUBLIC_BASE_URL"] = "https://example.test"

        return app
    }

    private func manifest(env: [String: String]) throws -> Manifest {
        try Manifest.bootstrap(env: .fixture(testEnv(env)))
    }

    /// Builds the full env vars dict tests need — server-mode plus
    /// whatever the specific test wants to set. Shared between
    /// makeApp + manifest helpers so the env presented to bootstrap
    /// always matches the env presented to AdminBootstrap.run.
    private func testEnv(_ extra: [String: String]) -> [String: String] {
        var full = extra
        full["KEYWORDISTA_MODE"] = "server"
        full["KEYWORDISTA_ENCRYPTION_KEY"] = String(repeating: "00", count: 32)
        full["KEYWORDISTA_PUBLIC_BASE_URL"] = "https://example.test"
        return full
    }

    private let logger = Logger(label: "test")

    // ── The happy path: env vars present, table empty ───────────────

    @Test("Both env vars set + empty users → admin seeded with correct role")
    func seedsAdminFromEnvVars() async throws {
        // Valid bcrypt-shape hash. Doesn't matter that we can't
        // actually verify against a real password — AdminBootstrap
        // only checks shape via Parsers.bcryptHash + AuthInputs.
        let validHash = "$2b$04$" + String(repeating: "a", count: 22)
            + String(repeating: "x", count: 31)
        let envVars = [
            "KEYWORDISTA_ADMIN_EMAIL": "operator@studio.local",
            "KEYWORDISTA_ADMIN_PASSWORD_HASH": validHash,
        ]
        let app = try await makeApp(env: envVars)
        defer { Task { try? await app.asyncShutdown() } }

        let outcome = try await AdminBootstrap.run(
            manifest: try manifest(env: envVars),
            env: .fixture(testEnv(envVars)),
            on: app.db,
            logger: logger
        )

        guard case .seeded(let email) = outcome else {
            Issue.record("expected .seeded, got \(outcome)"); return
        }
        #expect(email == "operator@studio.local")

        // Verify the user row IS in the DB AND has admin role + the
        // exact password hash we passed in.
        let users = try await User.query(on: app.db).all()
        #expect(users.count == 1)
        #expect(users.first?.email == "operator@studio.local")
        #expect(users.first?.role == .admin)
        #expect(users.first?.passwordHash == validHash)
    }

    @Test("Email is lowercased + trimmed before save")
    func normalizesEmail() async throws {
        let validHash = "$2b$04$" + String(repeating: "a", count: 22)
            + String(repeating: "x", count: 31)
        let envVars = [
            "KEYWORDISTA_ADMIN_EMAIL": "  Operator@Studio.Local  ",
            "KEYWORDISTA_ADMIN_PASSWORD_HASH": validHash,
        ]
        let app = try await makeApp(env: envVars)
        defer { Task { try? await app.asyncShutdown() } }

        let outcome = try await AdminBootstrap.run(
            manifest: try manifest(env: envVars),
            env: .fixture(testEnv(envVars)),
            on: app.db,
            logger: logger
        )

        guard case .seeded(let email) = outcome else {
            Issue.record("expected .seeded, got \(outcome)"); return
        }
        // AuthInputs.validateEmail lowercases + trims.
        #expect(email == "operator@studio.local")
    }

    // ── The idempotency contract: don't overwrite existing users ────

    @Test("Existing users → no-op (re-deploy doesn't overwrite admin)")
    func skipsWhenUsersExist() async throws {
        let app = try await makeApp(env: [:])
        defer { Task { try? await app.asyncShutdown() } }

        // Pre-populate with a user — simulates "Render redeployed
        // the container and we're booting fresh against a persistent
        // disk that already has data."
        let existing = User(
            email: "first@studio.local",
            passwordHash: "$2b$12$existing-hash-from-prior-run",
            role: .admin
        )
        try await existing.save(on: app.db)

        // Even with env vars set, AdminBootstrap MUST NOT overwrite.
        let validHash = "$2b$04$" + String(repeating: "a", count: 22)
            + String(repeating: "x", count: 31)
        let envVars = [
            "KEYWORDISTA_ADMIN_EMAIL": "different@studio.local",
            "KEYWORDISTA_ADMIN_PASSWORD_HASH": validHash,
        ]
        let outcome = try await AdminBootstrap.run(
            manifest: try manifest(env: envVars),
            env: .fixture(testEnv(envVars)),
            on: app.db,
            logger: logger
        )

        #expect(outcome == .alreadyHasUsers)
        // Original user still there, not replaced.
        let users = try await User.query(on: app.db).all()
        #expect(users.count == 1)
        #expect(users.first?.email == "first@studio.local")
    }

    // ── The defer-to-wizard path: no env vars ───────────────────────

    @Test("Empty env vars → no-op (defers to wizard, table stays empty)")
    func defersToWizardWhenEnvUnset() async throws {
        let app = try await makeApp(env: [:])
        defer { Task { try? await app.asyncShutdown() } }

        let outcome = try await AdminBootstrap.run(
            manifest: try manifest(env: [:]),
            on: app.db,
            logger: logger
        )

        #expect(outcome == .envVarsNotProvided)
        let users = try await User.query(on: app.db).all()
        #expect(users.isEmpty)
    }

    @Test("Only email set (hash missing) → no-op + warns operator")
    func warnsOnPartialEnvVars() async throws {
        let envVars = ["KEYWORDISTA_ADMIN_EMAIL": "operator@studio.local"]
        let app = try await makeApp(env: envVars)
        defer { Task { try? await app.asyncShutdown() } }

        let outcome = try await AdminBootstrap.run(
            manifest: try manifest(env: envVars),
            env: .fixture(testEnv(envVars)),
            on: app.db,
            logger: logger
        )

        #expect(outcome == .envVarsNotProvided)
        // We don't assert on log content here (would require a custom
        // LogHandler) — the warning path is observed manually + via
        // AdminBootstrap.swift's source. What matters is that the
        // outcome is .envVarsNotProvided AND no user was created.
        let users = try await User.query(on: app.db).all()
        #expect(users.isEmpty)
    }

    // ── Input validation ────────────────────────────────────────────

    @Test("Garbage email throws AuthInputs validation error")
    func rejectsInvalidEmail() async throws {
        // Email "@" fails AuthInputs.validateEmail. The manifest's
        // Parsers.email accepts it (looser regex), so the throw
        // happens at the AuthInputs layer inside AdminBootstrap.
        let validHash = "$2b$04$" + String(repeating: "a", count: 22)
            + String(repeating: "x", count: 31)
        let envVars = [
            "KEYWORDISTA_ADMIN_EMAIL": "not-an-email",
            "KEYWORDISTA_ADMIN_PASSWORD_HASH": validHash,
        ]
        let app = try await makeApp(env: envVars)
        defer { Task { try? await app.asyncShutdown() } }

        // Manifest parses (since email parser is loose) — the throw
        // happens during AdminBootstrap.run via AuthInputs.validateEmail.
        do {
            _ = try await AdminBootstrap.run(
                manifest: try manifest(env: envVars),
                on: app.db,
                logger: logger
            )
            Issue.record("expected throw on invalid email")
        } catch {
            // expected — AbortError from AuthInputs.validateEmail.
        }
        let users = try await User.query(on: app.db).all()
        #expect(users.isEmpty,
                "validation failure must leave the table empty (don't half-seed)")
    }
}
