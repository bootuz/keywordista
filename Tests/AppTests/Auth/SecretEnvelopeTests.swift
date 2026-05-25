@testable import App
import Crypto
import Foundation
import Testing

@Suite("SecretEnvelope")
struct SecretEnvelopeTests {

    private static func freshBox() -> SecretBox {
        SecretBox(key: SymmetricKey(size: .bits256))
    }

    // ── Detection ────────────────────────────────────────────────────

    @Suite("isWrapped")
    struct DetectionTests {

        @Test("Recognizes the v1 prefix")
        func recognizesV1() {
            #expect(SecretEnvelope.isWrapped("enc:v1:abc") == true)
        }

        @Test("Rejects bare plaintext (legacy rows)")
        func rejectsPlaintext() {
            #expect(SecretEnvelope.isWrapped("-----BEGIN PRIVATE KEY-----") == false)
            #expect(SecretEnvelope.isWrapped("plain-secret-from-2024") == false)
            #expect(SecretEnvelope.isWrapped("") == false)
        }

        @Test("Doesn't fire on prefix lookalikes")
        func noFalsePositives() {
            // 'enc' as a substring elsewhere shouldn't trigger.
            #expect(SecretEnvelope.isWrapped("Senc:v1:") == false)
            #expect(SecretEnvelope.isWrapped("encv1:abc") == false)
            #expect(SecretEnvelope.isWrapped("enc:v2:abc") == false)   // future version
        }
    }

    // ── Wrap/unwrap round-trip ───────────────────────────────────────

    @Suite("wrap + unwrap")
    struct RoundTripTests {

        @Test("Round-trip recovers the original plaintext")
        func happyPath() throws {
            let box = SecretEnvelopeTests.freshBox()
            let plaintext = "-----BEGIN PRIVATE KEY-----\nFAKE\n-----END PRIVATE KEY-----"
            let stored = try SecretEnvelope.wrap(plaintext, with: box)
            let recovered = try SecretEnvelope.unwrap(stored, with: box)
            #expect(recovered == plaintext)
        }

        @Test("Wrapped output has the v1 prefix + base64-safe tail")
        func wrappedShape() throws {
            let box = SecretEnvelopeTests.freshBox()
            let stored = try SecretEnvelope.wrap("any", with: box)
            #expect(stored.hasPrefix(SecretEnvelope.v1Prefix))
            // Tail must be valid base64 (round-trips through Data init).
            let tail = String(stored.dropFirst(SecretEnvelope.v1Prefix.count))
            #expect(Data(base64Encoded: tail) != nil)
        }

        @Test("Two wraps of the same plaintext produce different stored strings (fresh nonce)")
        func nonDeterministic() throws {
            let box = SecretEnvelopeTests.freshBox()
            let a = try SecretEnvelope.wrap("same-input", with: box)
            let b = try SecretEnvelope.wrap("same-input", with: box)
            #expect(a != b)
            #expect(try SecretEnvelope.unwrap(a, with: box) == "same-input")
            #expect(try SecretEnvelope.unwrap(b, with: box) == "same-input")
        }
    }

    // ── Legacy plaintext pass-through ────────────────────────────────

    @Suite("unwrap: legacy plaintext")
    struct LegacyTests {

        @Test("Bare plaintext (no prefix) unwraps to itself unchanged")
        func plaintextPassthrough() throws {
            let box = SecretEnvelopeTests.freshBox()
            let legacy = "the-pem-from-before-M1.9-ran"
            let unwrapped = try SecretEnvelope.unwrap(legacy, with: box)
            #expect(unwrapped == legacy)
        }

        @Test("Empty string passes through to empty (no decryption attempted)")
        func emptyPassthrough() throws {
            let box = SecretEnvelopeTests.freshBox()
            let unwrapped = try SecretEnvelope.unwrap("", with: box)
            #expect(unwrapped == "")
        }
    }

    // ── Failure modes ────────────────────────────────────────────────

    @Suite("unwrap: failure modes")
    struct FailureTests {

        @Test("Prefix-but-malformed-base64 throws malformedBase64")
        func badBase64() {
            let box = SecretEnvelopeTests.freshBox()
            do {
                _ = try SecretEnvelope.unwrap("enc:v1:!!!not-base64!!!", with: box)
                Issue.record("expected throw")
            } catch let err as SecretEnvelopeError {
                #expect(err == .malformedBase64)
            } catch {
                Issue.record("expected SecretEnvelopeError, got \(error)")
            }
        }

        @Test("Wrong key (envelope valid but sealed under a different SecretBox) fails")
        func wrongKey() throws {
            let alice = SecretEnvelopeTests.freshBox()
            let bob = SecretEnvelopeTests.freshBox()
            let stored = try SecretEnvelope.wrap("alice's secret", with: alice)
            #expect(throws: (any Error).self) {
                _ = try SecretEnvelope.unwrap(stored, with: bob)
            }
        }
    }
}
