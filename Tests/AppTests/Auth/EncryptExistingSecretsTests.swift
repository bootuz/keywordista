@testable import App
import Crypto
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

/// Real-DB test of the M1.9 EncryptExistingSecrets migration.
///
/// Unlike the rest of M1 (where we tested pure logic against
/// in-memory fixtures and deferred HTTP integration to M1.12), this
/// one needs Fluent's actual `Database` because:
///   1. AsyncMigration.prepare(on: any Database) takes a Database.
///   2. The migration uses Fluent's query DSL on real Setting rows.
///   3. The whole point of M1.9 is to verify that rows in a REAL
///      DB get converted to encrypted form correctly.
///
/// We spin up an isolated in-memory SQLite per test via Vapor's
/// `Application` — no shared state between tests, no cleanup needed.
@Suite("EncryptExistingSecrets (M1.9 migration)")
struct EncryptExistingSecretsTests {

    /// Build an Application + register the Setting schema. Each test
    /// gets a fresh in-memory DB so iteration order, concurrent test
    /// runners, etc. don't matter.
    private static func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateSetting())
        try await app.autoMigrate()
        return app
    }

    /// Seed the Setting table with a mix of secret-shaped (plaintext)
    /// + non-secret rows so each test can assert "only the right
    /// rows were touched."
    private static func seedMixedRows(
        on db: any Database,
        ascPlaintext: String = "-----BEGIN PRIVATE KEY-----\nP8\n-----END",
        asaPlaintext: String = "the-asa-secret-jwt"
    ) async throws {
        try await Setting(key: "asc.keyId", value: "OLDK").save(on: db)
        try await Setting(key: "asc.issuerId", value: "OLDISS").save(on: db)
        try await Setting(key: "asc.privateKey", value: ascPlaintext).save(on: db)
        try await Setting(key: "asa.clientId", value: "OLDCLIENT").save(on: db)
        try await Setting(key: "asa.clientSecret", value: asaPlaintext).save(on: db)
        try await Setting(key: "asa.orgId", value: "OLDORG").save(on: db)
    }

    private static func freshBox() -> SecretBox {
        SecretBox(key: SymmetricKey(size: .bits256))
    }

    // ── Happy path: legacy plaintext → enc:v1: envelope ─────────────

    @Test("prepare wraps secret-shaped plaintext rows in enc:v1: envelopes")
    func prepareWrapsSecrets() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Self.seedMixedRows(on: app.db)

        let box = Self.freshBox()
        try await EncryptExistingSecrets(secretBox: box).prepare(on: app.db)

        // The two secret-shaped rows are now wrapped + decrypt back
        // to the original plaintext.
        let secrets = try await Setting.query(on: app.db)
            .filter(\.$key ~~ ["asc.privateKey", "asa.clientSecret"])
            .all()
        for row in secrets {
            #expect(SecretEnvelope.isWrapped(row.value), "\(row.key) should be wrapped, got \(row.value.prefix(20))")
        }
        let ascRow = secrets.first { $0.key == "asc.privateKey" }!
        let asaRow = secrets.first { $0.key == "asa.clientSecret" }!
        let recoveredASC = try SecretEnvelope.unwrap(ascRow.value, with: box)
        let recoveredASA = try SecretEnvelope.unwrap(asaRow.value, with: box)
        #expect(recoveredASC == "-----BEGIN PRIVATE KEY-----\nP8\n-----END")
        #expect(recoveredASA == "the-asa-secret-jwt")
    }

    @Test("prepare leaves non-secret-shaped rows untouched")
    func nonSecretsUntouched() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Self.seedMixedRows(on: app.db)

        let box = Self.freshBox()
        try await EncryptExistingSecrets(secretBox: box).prepare(on: app.db)

        // Identifiers should be byte-identical to the seed.
        let nonSecrets = try await Setting.query(on: app.db)
            .filter(\.$key ~~ ["asc.keyId", "asc.issuerId", "asa.clientId", "asa.orgId"])
            .all()
        let asMap = Dictionary(uniqueKeysWithValues: nonSecrets.map { ($0.key, $0.value) })
        #expect(asMap["asc.keyId"] == "OLDK")
        #expect(asMap["asc.issuerId"] == "OLDISS")
        #expect(asMap["asa.clientId"] == "OLDCLIENT")
        #expect(asMap["asa.orgId"] == "OLDORG")
    }

    // ── Idempotency ─────────────────────────────────────────────────

    @Test("prepare is idempotent: second run skips already-wrapped rows")
    func idempotent() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Self.seedMixedRows(on: app.db)

        let box = Self.freshBox()
        let migration = EncryptExistingSecrets(secretBox: box)
        try await migration.prepare(on: app.db)

        // Snapshot after first run.
        let firstRun = try await Setting.query(on: app.db)
            .filter(\.$key == "asc.privateKey").first()!.value

        try await migration.prepare(on: app.db)

        // Second run is a no-op: the row's value is byte-identical
        // (NOT re-encrypted with a new nonce — that would change the
        // ciphertext). This is what makes the migration safe to run
        // again on partial failures or operator reverts.
        let secondRun = try await Setting.query(on: app.db)
            .filter(\.$key == "asc.privateKey").first()!.value
        #expect(firstRun == secondRun)
    }

    @Test("Empty values are skipped (no encryption of empty strings)")
    func skipsEmpty() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Setting(key: "asc.privateKey", value: "").save(on: app.db)

        let box = Self.freshBox()
        try await EncryptExistingSecrets(secretBox: box).prepare(on: app.db)

        let row = try await Setting.query(on: app.db)
            .filter(\.$key == "asc.privateKey").first()!
        #expect(row.value == "")
    }

    // ── Revert ──────────────────────────────────────────────────────

    @Test("revert unwraps enc:v1: envelopes back to plaintext")
    func revertUnwraps() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Self.seedMixedRows(on: app.db)

        let box = Self.freshBox()
        let migration = EncryptExistingSecrets(secretBox: box)
        try await migration.prepare(on: app.db)
        try await migration.revert(on: app.db)

        let secrets = try await Setting.query(on: app.db)
            .filter(\.$key ~~ ["asc.privateKey", "asa.clientSecret"])
            .all()
        let asMap = Dictionary(uniqueKeysWithValues: secrets.map { ($0.key, $0.value) })
        #expect(asMap["asc.privateKey"] == "-----BEGIN PRIVATE KEY-----\nP8\n-----END")
        #expect(asMap["asa.clientSecret"] == "the-asa-secret-jwt")
        // And the envelope prefix is gone.
        for (_, value) in asMap {
            #expect(!SecretEnvelope.isWrapped(value))
        }
    }

    @Test("revert is idempotent: second revert skips already-plaintext rows")
    func revertIdempotent() async throws {
        let app = try await Self.makeApp()
        defer { Task { try? await app.asyncShutdown() } }
        try await Self.seedMixedRows(on: app.db)

        let box = Self.freshBox()
        let migration = EncryptExistingSecrets(secretBox: box)
        try await migration.prepare(on: app.db)
        try await migration.revert(on: app.db)
        try await migration.revert(on: app.db) // should be a no-op

        let asc = try await Setting.query(on: app.db)
            .filter(\.$key == "asc.privateKey").first()!
        #expect(asc.value == "-----BEGIN PRIVATE KEY-----\nP8\n-----END")
    }
}
