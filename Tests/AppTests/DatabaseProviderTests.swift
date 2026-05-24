@testable import App
import Foundation
import Testing

@Suite("DatabaseProvider")
struct DatabaseProviderTests {

    // ── Routing ──────────────────────────────────────────────────────

    @Suite("resolve(from:)")
    struct ResolutionTests {

        @Test("server mode + empty env → SQLite with the documented /data default")
        func serverEmptyEnvIsSQLite() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://example.com",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            // Resolution calls back into the manifest; need to substitute
            // the same fixture through it.
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .sqlite(path: "/data/db.sqlite"))
        }

        @Test("local mode + empty env → SQLite with the cwd-relative dev default")
        func localEmptyEnvIsSQLite() throws {
            let env = ManifestEnv.fixture(["KEYWORDISTA_MODE": "local"])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .sqlite(path: "db.sqlite"))
        }

        @Test("Explicit DATABASE_PATH overrides the mode default")
        func explicitPathOverride() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "local",
                "DATABASE_PATH": "/tmp/custom.sqlite",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .sqlite(path: "/tmp/custom.sqlite"))
        }

        @Test("DATABASE_URL with postgres:// scheme → Postgres")
        func postgresURLRouting() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://example.com",
                "DATABASE_URL": "postgres://user:pass@host:5432/keywordista",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .postgres(url: "postgres://user:pass@host:5432/keywordista"))
        }

        @Test("DATABASE_URL with postgresql:// (PEP-compliant alias) also routes to Postgres")
        func postgresqlAliasRoutes() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://example.com",
                "DATABASE_URL": "postgresql://x@y/z",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .postgres(url: "postgresql://x@y/z"))
        }

        @Test("DATABASE_URL with unrelated scheme falls back to SQLite (not an error)")
        func unrelatedURLFallsBack() throws {
            // The contract is "use Postgres iff postgres scheme." Anything
            // else (mysql://, sqlite:///, even garbage) should fall back
            // to the SQLite path. This is defensive: a user who accidentally
            // pastes 'sqlite:///data/db.sqlite' shouldn't get Postgres
            // semantics applied to it.
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://example.com",
                "DATABASE_URL": "mysql://x@y/z",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .sqlite(path: "/data/db.sqlite"))
        }

        @Test("DATABASE_URL takes precedence over DATABASE_PATH when both set with Postgres URL")
        func urlBeatsPathWhenPostgres() throws {
            let env = ManifestEnv.fixture([
                "KEYWORDISTA_MODE": "server",
                "KEYWORDISTA_ENCRYPTION_KEY": String(repeating: "00", count: 32),
                "KEYWORDISTA_PUBLIC_BASE_URL": "https://example.com",
                "DATABASE_PATH": "/tmp/ignored.sqlite",
                "DATABASE_URL": "postgres://x@y/z",
            ])
            let manifest = try Manifest.bootstrap(env: env)
            let provider = try DatabaseProvider.resolve(from: manifest, env: env)
            #expect(provider == .postgres(url: "postgres://x@y/z"))
        }
    }

    // ── Diagnostics ──────────────────────────────────────────────────

    @Suite("Display & logging")
    struct DiagnosticsTests {

        @Test("displayName never leaks the connection string")
        func displayNameIsSafe() {
            let p = DatabaseProvider.postgres(url: "postgres://user:s3cr3t@host/db")
            // Plain "postgres" — no URL, no credentials, no host.
            #expect(p.displayName == "postgres")
            let s = DatabaseProvider.sqlite(path: "/data/db.sqlite")
            #expect(s.displayName == "sqlite")
        }
    }
}

