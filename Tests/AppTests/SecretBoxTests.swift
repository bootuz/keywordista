@testable import App
import Crypto
import Foundation
import Testing

@Suite("SecretBox")
struct SecretBoxTests {

    private static func freshBox() -> SecretBox {
        SecretBox(key: SymmetricKey(size: .bits256))
    }

    // ── Happy paths ──────────────────────────────────────────────────

    @Test("Round-trip: seal then open returns the original bytes")
    func roundTrip() throws {
        let box = Self.freshBox()
        let plaintext = Data("the password is 'swordfish'".utf8)
        let envelope = try box.seal(plaintext)
        let recovered = try box.open(envelope)
        #expect(recovered == plaintext)
    }

    @Test("String convenience: sealString → openString round-trips")
    func stringRoundTrip() throws {
        let box = Self.freshBox()
        let pem = """
        -----BEGIN PRIVATE KEY-----
        FAKEKEYFORTESTING==
        -----END PRIVATE KEY-----
        """
        let envelope = try box.sealString(pem)
        let recovered = try box.openString(envelope)
        #expect(recovered == pem)
    }

    @Test("Sealing the same plaintext twice produces different envelopes")
    func noncesAreUnique() throws {
        // AES-GCM with a fresh random nonce per call: two seals of the
        // same plaintext under the same key MUST produce different
        // ciphertexts. This is the property that prevents traffic
        // analysis ("oh look, the same encrypted thing appeared twice").
        let box = Self.freshBox()
        let plaintext = Data("same input".utf8)
        let a = try box.seal(plaintext)
        let b = try box.seal(plaintext)
        #expect(a != b)
    }

    // ── Failure modes ────────────────────────────────────────────────

    @Test("Opening with a different key fails")
    func wrongKey() throws {
        let alice = Self.freshBox()
        let bob = Self.freshBox()
        let envelope = try alice.seal(Data("secret".utf8))
        #expect(throws: (any Error).self) {
            _ = try bob.open(envelope)
        }
    }

    @Test("Tampering with the ciphertext is detected by the GCM auth tag")
    func tamperingDetected() throws {
        let box = Self.freshBox()
        let envelope = try box.seal(Data("important data".utf8))
        var tampered = envelope
        // Flip a bit somewhere in the middle of the ciphertext (well
        // past the 12-byte nonce header, well before the trailing tag).
        let i = tampered.count / 2
        tampered[i] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try box.open(tampered)
        }
    }

    @Test("Truncated envelope yields a structured malformed error")
    func truncatedEnvelopeMalformed() {
        let box = Self.freshBox()
        let tooShort = Data([0x01, 0x02, 0x03])  // < 12 bytes
        do {
            _ = try box.open(tooShort)
            Issue.record("expected throw")
        } catch let err as SecretBoxError {
            // Either form is acceptable — what matters is we got our
            // own error type, not a raw CryptoKit error.
            if case .envelopeMalformed = err { /* ok */ }
            else { Issue.record("expected .envelopeMalformed, got \(err)") }
        } catch {
            Issue.record("expected SecretBoxError, got \(error)")
        }
    }

    @Test("openString fails cleanly when the decrypted bytes aren't UTF-8")
    func openStringRejectsNonUTF8() throws {
        let box = Self.freshBox()
        // Bytes that are valid as Data but not as UTF-8.
        let nonUTF8 = Data([0xC3, 0x28])
        let envelope = try box.seal(nonUTF8)
        do {
            _ = try box.openString(envelope)
            Issue.record("expected throw")
        } catch let err as SecretBoxError {
            #expect(err == .openedBytesNotUTF8)
        } catch {
            Issue.record("expected SecretBoxError.openedBytesNotUTF8, got \(error)")
        }
    }
}
