@testable import App
import Crypto
import Foundation
import Testing

@Suite("SettingsService — encryption at rest (M1.9)")
struct SettingsServiceEncryptionTests {

    /// Two fresh SecretBoxes wrapping the SAME random key — lets us
    /// hand one to SettingsService and use the other to manually
    /// unwrap stored values for assertions.
    private static func twinBoxes() -> (SecretBox, SecretBox) {
        let key = SymmetricKey(size: .bits256)
        return (SecretBox(key: key), SecretBox(key: key))
    }

    // ── ASC ──────────────────────────────────────────────────────────

    @Suite("ASC")
    struct ASCTests {

        @Test("setASCCredentials stores asc.privateKey as an enc:v1: envelope (NOT plaintext)")
        func storesEncrypted() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            try await svc.setASCCredentials(ASCCredentials(
                keyId: "K123",
                issuerId: "ISS456",
                privateKey: "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----"
            ))

            let storedKey = await repo.rawValue(of: "asc.privateKey")
            #expect(storedKey != nil)
            #expect(SecretEnvelope.isWrapped(storedKey!) == true)
            // Critically: the plaintext is NOT visible in the stored
            // value. If a row leaks via backup / log / DB dump,
            // the .p8 is unreadable without the encryption key.
            #expect(!(storedKey!).contains("BEGIN PRIVATE KEY"))
        }

        @Test("Non-secret-shaped keys (asc.keyId, asc.issuerId) stay plaintext")
        func nonSecretsArePlaintext() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            try await svc.setASCCredentials(ASCCredentials(
                keyId: "K123",
                issuerId: "ISS456",
                privateKey: "anything"
            ))

            // keyId + issuerId are identifiers, not secrets — they
            // should round-trip as the same plaintext.
            #expect(await repo.rawValue(of: "asc.keyId") == "K123")
            #expect(await repo.rawValue(of: "asc.issuerId") == "ISS456")
        }

        @Test("getASCCredentials decrypts on read (round-trips back to plaintext)")
        func roundTrip() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)
            let plaintext = "-----BEGIN PRIVATE KEY-----\nROUND\n-----END PRIVATE KEY-----"

            try await svc.setASCCredentials(ASCCredentials(
                keyId: "K", issuerId: "I", privateKey: plaintext
            ))

            let recovered = try await svc.getASCCredentials()
            #expect(recovered?.privateKey == plaintext)
            #expect(recovered?.keyId == "K")
            #expect(recovered?.issuerId == "I")
        }

        @Test("Legacy plaintext (pre-M1.9 row) reads back unchanged")
        func legacyPlaintextPassThrough() async throws {
            // Simulates a pre-M1.9 row: the repo holds the value
            // without the enc:v1: prefix. SettingsService should
            // pass it through unchanged so a freshly-deployed
            // server can still read its existing ASC creds before
            // the EncryptExistingSecrets migration runs.
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository(seed: [
                "asc.keyId": "OLDK",
                "asc.issuerId": "OLDISS",
                "asc.privateKey": "legacy-plaintext-pem",
            ])
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            let recovered = try await svc.getASCCredentials()
            #expect(recovered?.privateKey == "legacy-plaintext-pem")
        }

        @Test("getASCStatus.hasPrivateKey works without decryption")
        func statusCheckDoesNotDecrypt() async throws {
            // hasPrivateKey is "is the row present and non-empty?" —
            // it should NOT require decrypting the value. Set a row
            // that SettingsService didn't write (no envelope prefix
            // and not even a valid envelope) and confirm status
            // reports it as present.
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository(seed: [
                "asc.privateKey": "raw-non-envelope-string",
            ])
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            let status = try await svc.getASCStatus()
            #expect(status.hasPrivateKey == true)
        }
    }

    // ── ASA ──────────────────────────────────────────────────────────

    @Suite("ASA")
    struct ASATests {

        @Test("setASACredentials encrypts client_secret only")
        func encryptsOnlyClientSecret() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            try await svc.setASACredentials(ASACredentials(
                clientId: "CLIENT_X",
                clientSecret: "super-secret-jwt",
                orgId: "ORG_42"
            ))

            #expect(await repo.rawValue(of: "asa.clientId") == "CLIENT_X")
            #expect(await repo.rawValue(of: "asa.orgId") == "ORG_42")
            let storedSecret = await repo.rawValue(of: "asa.clientSecret")
            #expect(SecretEnvelope.isWrapped(storedSecret!) == true)
            #expect(!(storedSecret!).contains("super-secret-jwt"))
        }

        @Test("getASACredentials round-trips through encryption")
        func roundTrip() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            try await svc.setASACredentials(ASACredentials(
                clientId: "C", clientSecret: "the-jwt-bytes", orgId: nil
            ))
            let recovered = try await svc.getASACredentials()
            #expect(recovered?.clientSecret == "the-jwt-bytes")
            #expect(recovered?.clientId == "C")
        }
    }

    // ── Clear / delete ───────────────────────────────────────────────

    @Suite("Clear")
    struct ClearTests {

        @Test("clearASCCredentials removes all three keys regardless of envelope state")
        func clearASC() async throws {
            let (serviceBox, _) = SettingsServiceEncryptionTests.twinBoxes()
            let repo = InMemorySettingsRepository()
            let svc = SettingsService(repository: repo, secretBox: serviceBox)

            try await svc.setASCCredentials(ASCCredentials(
                keyId: "K", issuerId: "I", privateKey: "pem"
            ))
            try await svc.clearASCCredentials()

            #expect(await repo.rawValue(of: "asc.keyId") == nil)
            #expect(await repo.rawValue(of: "asc.issuerId") == nil)
            #expect(await repo.rawValue(of: "asc.privateKey") == nil)
        }
    }
}
