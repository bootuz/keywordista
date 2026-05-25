@testable import App
import Foundation
import Testing

@Suite("PasswordHasher")
struct PasswordHasherTests {

    // Lowest valid cost (4) — keeps the suite fast. Cost 4 is
    // bcrypt-spec-minimum but still produces a real hash; the actual
    // cost in production is 12 from the manifest default.
    private static let testCost = 4

    private static func freshHasher() throws -> PasswordHasher {
        try PasswordHasher(cost: testCost)
    }

    // ── Cost validation at init ──────────────────────────────────────

    @Suite("Cost validation")
    struct CostTests {

        @Test("Accepts costs in the [4, 31] range")
        func acceptsValid() throws {
            for cost in [4, 10, 12, 14, 31] {
                _ = try PasswordHasher(cost: cost)
            }
        }

        @Test("Rejects cost below 4 (bcrypt minimum)")
        func rejectsTooLow() {
            for cost in [-1, 0, 1, 3] {
                #expect(throws: PasswordHasherError.self) {
                    _ = try PasswordHasher(cost: cost)
                }
            }
        }

        @Test("Rejects cost above 31 (bcrypt maximum)")
        func rejectsTooHigh() {
            for cost in [32, 50, 1000] {
                #expect(throws: PasswordHasherError.self) {
                    _ = try PasswordHasher(cost: cost)
                }
            }
        }

        @Test("Error names the bad value")
        func errorIsSpecific() {
            do {
                _ = try PasswordHasher(cost: 100)
                Issue.record("expected throw")
            } catch let err as PasswordHasherError {
                #expect(err == .costOutOfRange(got: 100))
                #expect("\(err)".contains("100"))
            } catch {
                Issue.record("expected PasswordHasherError, got \(error)")
            }
        }
    }

    // ── Hash + verify round-trip ─────────────────────────────────────

    @Suite("Hash + verify")
    struct RoundTripTests {

        @Test("hash then verify with same password returns true")
        func happyPath() async throws {
            let h = try PasswordHasherTests.freshHasher()
            let plaintext = "swordfish-42"
            let stored = try await h.hash(plaintext)
            let ok = try await h.verify(plaintext, against: stored)
            #expect(ok == true)
        }

        @Test("verify with a different password returns false")
        func wrongPassword() async throws {
            let h = try PasswordHasherTests.freshHasher()
            let stored = try await h.hash("the-correct-one")
            let ok = try await h.verify("the-wrong-one", against: stored)
            #expect(ok == false)
        }

        @Test("Two hashes of the same password produce different strings (salt)")
        func freshSaltEveryTime() async throws {
            // bcrypt randomizes the salt per call; this is what prevents
            // a rainbow-table attack against the stored hashes.
            let h = try PasswordHasherTests.freshHasher()
            let plaintext = "hunter2"
            let a = try await h.hash(plaintext)
            let b = try await h.hash(plaintext)
            #expect(a != b)
            // Both still verify back to the same plaintext.
            #expect(try await h.verify(plaintext, against: a) == true)
            #expect(try await h.verify(plaintext, against: b) == true)
        }

        @Test("Hashes are MCF-format bcrypt strings starting with $2…$")
        func hashFormat() async throws {
            let h = try PasswordHasherTests.freshHasher()
            let stored = try await h.hash("any")
            // Bcrypt MCF: $2a$ / $2b$ / $2y$; Vapor emits $2b$.
            #expect(stored.hasPrefix("$2"))
            #expect(stored.count >= 59 && stored.count <= 64)
        }
    }

    // ── Verify error surface ─────────────────────────────────────────

    @Suite("Verify failure modes")
    struct VerifyFailureTests {

        @Test("Malformed hash string throws malformedHash, not silent false")
        func rejectsGarbage() async throws {
            // The auth layer needs to distinguish 'user typed wrong
            // password' (false) from 'DB has corrupt data' (throw)
            // so it can log + alert on the latter. Silently returning
            // false here would mask data corruption.
            let h = try PasswordHasherTests.freshHasher()
            await #expect(throws: PasswordHasherError.self) {
                _ = try await h.verify("any", against: "not-a-bcrypt-hash-at-all")
            }
        }

        @Test("Verifying an empty password against a real hash returns false")
        func emptyPasswordIsJustWrong() async throws {
            let h = try PasswordHasherTests.freshHasher()
            let stored = try await h.hash("nonempty")
            let ok = try await h.verify("", against: stored)
            #expect(ok == false)
        }
    }
}
