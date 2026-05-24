import Fluent
import Foundation

/// One-time data migration that normalizes credential-shaped Setting
/// rows from legacy plaintext into the M1.9 `enc:v1:` envelope.
///
/// Why this isn't a schema migration: the Setting table's `value`
/// column is already a plain `String`, which holds the base64-of-
/// ciphertext envelope just fine. The change is purely in what
/// shape of String we write — no ALTER TABLE needed.
///
/// **Idempotent on both directions** (matters because Fluent records
/// migration runs once, but operators who hand-revert or restore from
/// a partial backup deserve to land in a sane state regardless):
///   • `prepare()`: rows already in `enc:v1:` form are skipped; only
///     legacy plaintext rows are wrapped.
///   • `revert()`: rows in `enc:v1:` form are unwrapped back to
///     plaintext; rows already plain are skipped.
///
/// **Why migration carries its own SecretBox**: Fluent migrations
/// only receive a `Database` instance at run time, not an
/// `Application`. The SecretBox is resolved once in configure.swift
/// from the operator's encryption key + manifest mode, and the same
/// instance is both:
///   1. Stashed in `app.secretBox` for runtime service injection
///      (see Application+SecretBox.swift).
///   2. Passed to this migration's init when it's added to
///      `app.migrations`.
/// That way prepare/revert see the same crypto state production
/// code uses.
///
/// **Scope**: only `asc.privateKey` + `asa.clientSecret` (the
/// SettingsService.Keys.secretShaped set). asc.keyId / asc.issuerId
/// / asa.clientId / asa.orgId are identifiers, not secrets — they
/// stay plaintext.
struct EncryptExistingSecrets: AsyncMigration {

    let secretBox: SecretBox

    func prepare(on database: any Database) async throws {
        let candidates = try await Setting.query(on: database)
            .filter(\.$key ~~ SettingsService.Keys.secretShaped)
            .all()

        for row in candidates {
            // Skip empty values (operator never set a credential) and
            // already-wrapped values (idempotency).
            if row.value.isEmpty || SecretEnvelope.isWrapped(row.value) {
                continue
            }
            row.value = try SecretEnvelope.wrap(row.value, with: secretBox)
            try await row.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        let candidates = try await Setting.query(on: database)
            .filter(\.$key ~~ SettingsService.Keys.secretShaped)
            .all()

        for row in candidates {
            if row.value.isEmpty || !SecretEnvelope.isWrapped(row.value) {
                continue
            }
            row.value = try SecretEnvelope.unwrap(row.value, with: secretBox)
            try await row.save(on: database)
        }
    }
}
