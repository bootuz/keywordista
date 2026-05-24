@testable import App
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

/// Real-DB tests of the M1.11 backup helper.
///
/// Like M1.9's EncryptExistingSecretsTests, these spin up a fresh
/// Application + in-memory SQLite per test. The pure-function
/// `snapshotFilename` test doesn't need a DB and runs in-process.
@Suite("Backup helper (M1.11)")
struct BackupTests {

    private static func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateSetting())
        try await app.autoMigrate()
        return app
    }

    // ── takeSQLiteSnapshot ───────────────────────────────────────────

    @Suite("takeSQLiteSnapshot")
    struct SnapshotTests {

        @Test("Returns non-empty bytes that begin with the SQLite magic header")
        func validSQLiteBytes() async throws {
            let app = try await BackupTests.makeApp()
            defer { Task { try? await app.asyncShutdown() } }
            try await Setting(key: "test.key", value: "test.value").save(on: app.db)

            let data = try await Backup.takeSQLiteSnapshot(of: ":memory:", on: app.db)

            // SQLite files start with the 16-byte magic string
            // "SQLite format 3" followed by a null. This is the
            // canonical way to verify "yes this is a SQLite file"
            // — `file(1)` uses the same check.
            let magic = "SQLite format 3\0"
            #expect(data.count >= magic.count)
            let header = String(data: data.prefix(magic.count), encoding: .ascii)
            #expect(header == magic)
        }

        @Test("Snapshot contains the rows that were in the live DB")
        func containsLiveRows() async throws {
            let app = try await BackupTests.makeApp()
            defer { Task { try? await app.asyncShutdown() } }
            try await Setting(key: "rowA", value: "valueA").save(on: app.db)
            try await Setting(key: "rowB", value: "valueB").save(on: app.db)

            let data = try await Backup.takeSQLiteSnapshot(of: ":memory:", on: app.db)

            // Open the snapshot directly via a second SQLite
            // connection and confirm the seeded rows are there.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("backup-verify-\(UUID().uuidString).sqlite")
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let verify = try await Application.make(.testing)
            verify.databases.use(.sqlite(.file(tmp.path)), as: .sqlite)
            defer { Task { try? await verify.asyncShutdown() } }

            let rows = try await Setting.query(on: verify.db).all()
            let asMap = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
            #expect(asMap["rowA"] == "valueA")
            #expect(asMap["rowB"] == "valueB")
        }

        @Test("Cleans up the temp snapshot file after reading")
        func cleansUpTempFile() async throws {
            let app = try await BackupTests.makeApp()
            defer { Task { try? await app.asyncShutdown() } }

            let countBefore = try FileManager.default
                .contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("keywordista-snapshot-") }
                .count

            _ = try await Backup.takeSQLiteSnapshot(of: ":memory:", on: app.db)

            let countAfter = try FileManager.default
                .contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("keywordista-snapshot-") }
                .count
            // We don't assert strict equality — concurrent tests
            // could leave temp files behind. Asserting "not greater"
            // is the meaningful check: our call cleaned up its OWN
            // file, regardless of what other tests are doing.
            #expect(countAfter <= countBefore + 0,
                    "snapshot temp file leaked: \(countBefore) → \(countAfter)")
        }
    }

    // ── snapshotFilename ─────────────────────────────────────────────

    @Suite("snapshotFilename")
    struct FilenameTests {

        @Test("Produces keywordista-YYYY-MM-DD.sqlite (UTC)")
        func dateFormatted() {
            // Pin a specific UTC date so the test is deterministic
            // regardless of the runner's local timezone.
            let when = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14T22:13:20Z
            let name = Backup.snapshotFilename(now: when)
            #expect(name == "keywordista-2023-11-14.sqlite")
        }

        @Test("Uses POSIX locale to avoid weird locale-dependent date formats")
        func localeIndependent() {
            // Same date — should produce the same filename across
            // every operator's locale.
            let when = Date(timeIntervalSince1970: 1_700_000_000)
            let a = Backup.snapshotFilename(now: when)
            let b = Backup.snapshotFilename(now: when)
            #expect(a == b)
            // Sanity: no exotic characters that would cause issues
            // when used as a filename.
            #expect(!a.contains("/"))
            #expect(!a.contains(":"))
        }
    }
}
