import Fluent
import Foundation
import SQLKit
import Vapor

/// Backup endpoint. POST /api/v1/admin/backup → snapshot bytes in
/// the response body.
///
/// The cockpit's BackupDownloader (M5) hits this from either a local
/// or remote Keywordista instance with the same code path — that's
/// why the same controller is registered in BOTH local mode (under
/// /api/v1, no auth) and server mode (under the admin group, gated
/// by RoleMiddleware.requireAdmin).
///
/// **SQLite path**: `VACUUM INTO` writes a clean, consistent
/// snapshot of the live WAL-mode database to a temp file. We read
/// the file bytes into the HTTP response and delete the temp file.
/// Works while the binary is serving other requests; no locking.
///
/// **Postgres path**: returns 501 Not Implemented with a clear
/// "use pg_dump or your provider's snapshot tool" message. Full
/// pg_dump support via Process shell-out + image bundling of
/// postgresql-client is a later refinement once the cockpit has a
/// real consumer needing it.
///
/// **Size note**: SQLite path reads the snapshot into memory. Fine
/// for the typical Keywordista DB (a few MB even for a busy team —
/// the schema is small, no binary blobs). Operators with multi-GB
/// DBs should use Litestream replication instead; the README docs
/// the trade-off.
struct BackupController {

    /// Registers the single route under the parent. Caller decides
    /// whether to gate behind admin (server mode → yes, local mode
    /// → no, same as every other controller).
    func register(on routes: any RoutesBuilder) {
        routes.post("backup", use: snapshot)
    }

    @Sendable func snapshot(req: Request) async throws -> Response {
        let provider = req.application.requireDatabaseProvider()

        switch provider {
        case .postgres:
            // Not implemented — semantically the right status. The
            // cockpit can render a useful message from this rather
            // than hitting a confusing 500.
            throw Abort(
                .notImplemented,
                reason: "Postgres backup isn't supported via this endpoint yet. Use pg_dump or your provider's snapshot tool (Render: 'Backups' tab; Fly: 'fly postgres backup')."
            )

        case .sqlite(let livePath):
            let data = try await Backup.takeSQLiteSnapshot(of: livePath, on: req.db)
            let response = Response(status: .ok)
            response.headers.contentType = HTTPMediaType(type: "application", subType: "x-sqlite3")
            response.headers.contentDisposition = .init(.attachment, filename: Backup.snapshotFilename())
            response.headers.add(name: .contentLength, value: "\(data.count)")
            response.body = .init(data: data)
            return response
        }
    }
}

// MARK: - Backup helper
//
// Pulled into its own enum so the snapshot logic is testable in
// isolation (no Vapor Request/Response needed). M1.11's tests
// exercise this directly against a real in-memory SQLite via
// Application.testing — same pattern M1.9's EncryptExistingSecretsTests
// established.

enum Backup {

    /// Live, consistent snapshot of `db.sqlite` via SQLite's
    /// `VACUUM INTO`. Writes to a temp path, reads the bytes
    /// back, deletes the temp file, returns the bytes.
    ///
    /// - Parameter livePath: path to the live SQLite file (used
    ///   only for naming the temp file — the snapshot is taken
    ///   via SQLite over the open Database connection, not by
    ///   reading the live path).
    /// - Parameter db: the Fluent Database that wraps the live
    ///   SQLite connection. We need this to issue the VACUUM
    ///   INTO statement.
    /// - Returns: the snapshot bytes.
    static func takeSQLiteSnapshot(
        of livePath: String,
        on db: any Database
    ) async throws -> Data {
        guard let sql = db as? any SQLDatabase else {
            // Defensive — caller shouldn't be giving us a non-SQL
            // database, but if they do, we want a clear failure.
            throw BackupError.notSQLDatabase
        }

        // Temp path: UUID-suffixed under the system temp dir so
        // concurrent backups (which shouldn't happen given the
        // admin-only gate, but defense-in-depth) don't collide.
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("keywordista-snapshot-\(UUID().uuidString).sqlite")
            .path

        // SQL string interpolation here is safe because the path is
        // server-controlled (built from UUID + system temp dir), not
        // operator-supplied. We still escape the apostrophes that
        // could appear in macOS user names ("/Users/Mary O'Brien/...")
        // by wrapping in double single-quotes per SQLite's rules.
        let escaped = tempPath.replacingOccurrences(of: "'", with: "''")
        try await sql.raw(SQLQueryString("VACUUM INTO '\(raw: escaped)'")).run()

        defer {
            // Best-effort cleanup. If this throws (permissions, etc.)
            // we don't care — we already have the bytes; the temp
            // file will get reaped at system level eventually.
            try? FileManager.default.removeItem(atPath: tempPath)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        return data
    }

    /// Operator-friendly filename: `keywordista-2026-05-24.sqlite`.
    /// Used in Content-Disposition so the cockpit/browser saves the
    /// file with a sensible name. Date suffix means consecutive
    /// backups don't overwrite each other in a single download dir.
    static func snapshotFilename(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return "keywordista-\(f.string(from: now)).sqlite"
    }
}

enum BackupError: Error, CustomStringConvertible, Equatable {
    case notSQLDatabase

    var description: String {
        switch self {
        case .notSQLDatabase:
            return "expected an SQL-capable database driver (SQLite); got something else"
        }
    }
}
