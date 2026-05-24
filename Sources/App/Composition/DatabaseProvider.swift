import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import SQLKit
import Vapor

/// Operator-facing database choice — resolved once at boot from the
/// EnvVarManifest, then handed to Fluent. The whole abstraction exists
/// at this one layer so call-sites (controllers, services, migrations)
/// never know which driver is underneath.
///
/// Routing rule (§4.10): if `DATABASE_URL` is set AND its scheme is
/// `postgres://` or `postgresql://`, use Postgres. Otherwise fall back
/// to SQLite at `DATABASE_PATH` (which itself has a mode-conditional
/// default — see EnvVars.databasePath).
///
/// Local mode (`KEYWORDISTA_MODE=local`, the menubar-spawned backend)
/// always resolves to SQLite — Postgres is intentionally a server-mode-
/// only concern. There's no reason to introduce a Postgres dependency
/// for the solo Mac path.
public enum DatabaseProvider: Sendable, Equatable {
    case sqlite(path: String)
    case postgres(url: String)

    // ── Resolution ────────────────────────────────────────────────────

    /// Single source of truth for the SQLite-vs-Postgres decision.
    /// `env` accepts the same `ManifestEnv` seam as the manifest, so
    /// tests fixture the env through both layers via one parameter.
    public static func resolve(
        from manifest: Manifest,
        env: ManifestEnv = .processEnv
    ) throws -> DatabaseProvider {
        if let url = try manifest.optional(EnvVars.databaseURL, env: env),
           url.hasPrefix("postgres://") || url.hasPrefix("postgresql://") {
            return .postgres(url: url)
        }
        let path = try manifest.require(EnvVars.databasePath, env: env)
        return .sqlite(path: path)
    }

    // ── Registration ──────────────────────────────────────────────────

    /// Wires the resolved driver into Vapor's Fluent stack. Idempotent
    /// per Application instance — Vapor's `databases.use(_:as:)` is
    /// itself a set, not an append.
    ///
    /// The same `.psql` / `.sqlite` identifiers are used by every model
    /// and migration in the codebase via Fluent's default `as: .sqlite`/
    /// `as: .psql` convention. Models don't pick — the registered driver
    /// at boot decides.
    public func register(on app: Application) throws {
        switch self {
        case .sqlite(let path):
            app.databases.use(.sqlite(.file(path)), as: .sqlite)

        case .postgres(let url):
            try app.databases.use(.postgres(url: url), as: .psql)
        }
    }

    // ── Driver-specific tuning ────────────────────────────────────────

    /// SQLite-only PRAGMAs that eliminate the "database is locked" storm
    /// we used to hit with parallel jobs. WAL mode lets a writer and
    /// many readers run concurrently without exclusive locks (persists
    /// in the .db file header — runs once, sticks across restarts).
    /// busy_timeout asks SQLite to wait up to 5s for a contended lock
    /// to clear instead of immediately returning SQLITE_BUSY.
    ///
    /// No-op for Postgres: equivalent concurrency comes for free from
    /// the server's MVCC; statement_timeout etc. are operator-tuned via
    /// the DATABASE_URL connection-string options.
    public func applyDriverSpecificTuning(on app: Application) async throws {
        guard case .sqlite = self else { return }
        if let sql = app.db as? any SQLDatabase {
            try await sql.raw("PRAGMA journal_mode=WAL").run()
            try await sql.raw("PRAGMA busy_timeout=5000").run()
        }
    }

    // ── Diagnostics ───────────────────────────────────────────────────

    /// Short label for /health and startup log line ("running with sqlite"
    /// vs "running with postgres"). Don't leak the connection string into
    /// logs — DATABASE_URL is `valueIsSecret: true` in the manifest.
    public var displayName: String {
        switch self {
        case .sqlite: return "sqlite"
        case .postgres: return "postgres"
        }
    }
}
