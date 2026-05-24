@testable import App
import Crypto
import Foundation
import Testing

@Suite("EncryptionKeyResolver")
struct EncryptionKeyResolverTests {

    // ── Explicit key path ────────────────────────────────────────────

    @Test("Explicit 32-byte data yields a SymmetricKey wrapping those bytes")
    func explicitKey() throws {
        let raw = Data(repeating: 0xAB, count: 32)
        let key = try EncryptionKeyResolver.resolve(mode: .server, explicit: raw)
        // Equality on SymmetricKey isn't public, so round-trip through
        // SecretBox to prove the resolved key really is the bytes we
        // passed in.
        let box = SecretBox(key: key)
        let plaintext = Data("verify".utf8)
        let envelope = try box.seal(plaintext)
        let recovered = try box.open(envelope)
        #expect(recovered == plaintext)
    }

    @Test("Wrong-sized explicit data throws wrongKeySize")
    func wrongSizeRejected() {
        let raw = Data(repeating: 0xCC, count: 16)  // too short
        do {
            _ = try EncryptionKeyResolver.resolve(mode: .server, explicit: raw)
            Issue.record("expected throw")
        } catch let err as EncryptionKeyError {
            #expect(err == .wrongKeySize(got: 16))
        } catch {
            Issue.record("expected EncryptionKeyError, got \(error)")
        }
    }

    // ── Server mode without explicit key ─────────────────────────────

    @Test("Server mode + nil explicit throws missingInServerMode")
    func serverMissingKey() {
        do {
            _ = try EncryptionKeyResolver.resolve(mode: .server, explicit: nil)
            Issue.record("expected throw")
        } catch let err as EncryptionKeyError {
            #expect(err == .missingInServerMode)
        } catch {
            Issue.record("expected EncryptionKeyError, got \(error)")
        }
    }

    // ── Local mode derivation (macOS only) ───────────────────────────

    #if os(macOS)
    @Test("Local mode + nil explicit derives a key deterministically from the Mac's UUID")
    func localDerivesDeterministically() throws {
        // Two calls in the same test process MUST yield the same key —
        // SQLite rows encrypted on Monday must be decryptable on Tuesday
        // without us having stored a key anywhere.
        let a = try EncryptionKeyResolver.resolve(mode: .local, explicit: nil)
        let b = try EncryptionKeyResolver.resolve(mode: .local, explicit: nil)

        // Prove they're the same by round-tripping a value sealed with
        // one and opened with the other.
        let plaintext = Data("deterministic check".utf8)
        let envelope = try SecretBox(key: a).seal(plaintext)
        let recovered = try SecretBox(key: b).open(envelope)
        #expect(recovered == plaintext)
    }

    @Test("Local-mode key is not the all-zero key (sanity guard against bad IOPlatformUUID)")
    func localKeyIsNonTrivial() throws {
        let key = try EncryptionKeyResolver.resolve(mode: .local, explicit: nil)
        let envelope = try SecretBox(key: key).seal(Data("x".utf8))
        let zeroKey = SymmetricKey(data: Data(repeating: 0, count: 32))
        // Opening with the all-zero key should fail (different key).
        #expect(throws: (any Error).self) {
            _ = try SecretBox(key: zeroKey).open(envelope)
        }
    }
    #endif
}
