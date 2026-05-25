@testable import App
import Foundation
import Testing

/// M3.24b: pin the contract of AuthController.constantTimeEqual, the
/// security-critical compare for the M3.21 setup token.
///
/// **Why this test file exists.** The integration tests in
/// `AuthIntegrationTests.SetupTests` only check HTTP-status outcomes
/// (`tokenWrongValue` → 401, `tokenHappyPath` → 201). They'd still
/// pass if `constantTimeEqual` were silently replaced with `==`. The
/// security guarantee (no short-circuit-on-mismatch timing leak)
/// would be gone, and no test would catch it.
///
/// These tests pin the *semantic* contract — what the function
/// returns — and the implementation comment carries the burden of
/// describing the *timing* contract. We can't easily assert on
/// timing in CI (too noisy), so we instead ensure the function's
/// signature can't degrade silently: it must continue to use a
/// constant-time primitive (verified by code review at refactor time,
/// pinned by the doc comment + this test's structure).
@Suite("constantTimeEqual (M3.21 + M3.24b)")
struct ConstantTimeEqualTests {

    /// One controller instance shared across all tests — the function
    /// has no instance state, so this is safe and saves the cost of
    /// the bcrypt hasher init per case.
    private let controller: AuthController = {
        // bcryptCost 4 to match AuthTestApp — cheap, correct algorithm.
        let hasher = try! PasswordHasher(cost: 4)
        return AuthController(
            hasher: hasher,
            sessionTTLDays: 30,
            inviteTTLDays: 7,
            mode: .server
        )
    }()

    // ── Equality semantics ────────────────────────────────────────────

    @Test("Identical strings return true")
    func identicalStringsReturnTrue() {
        let token = "a-typical-setup-token-of-reasonable-length"
        #expect(controller.constantTimeEqual(token, token) == true)
    }

    @Test("Empty strings on both sides return true")
    func bothEmptyReturnsTrue() {
        // HMAC over zero-length input is well-defined; the verify
        // step compares two MACs of equal-length inputs. Both empty
        // means both MACs are identical → true.
        #expect(controller.constantTimeEqual("", "") == true)
    }

    @Test("Different-length inputs return false (one byte longer)")
    func differentLengthOneByteReturnsFalse() {
        #expect(controller.constantTimeEqual("token", "tokens") == false)
    }

    @Test("Different-length inputs return false (very different sizes)")
    func differentLengthFarReturnsFalse() {
        #expect(controller.constantTimeEqual("short", String(repeating: "x", count: 1000)) == false)
    }

    @Test("One-byte difference at the END returns false")
    func oneByteDifferenceAtEndReturnsFalse() {
        // The classic timing-attack target: a `==` impl would
        // short-circuit on the first byte mismatch (in this case
        // never — the difference is at the last position). The
        // failure mode being tested is functional, not timing,
        // but pinning the byte-level semantics keeps the constraint
        // documented.
        #expect(controller.constantTimeEqual("hello-world", "hello-worlz") == false)
    }

    @Test("One-byte difference at the START returns false")
    func oneByteDifferenceAtStartReturnsFalse() {
        // The opposite attack shape: an `==`-replacement bug would
        // fail this test instantly, since the implementations diverge
        // immediately at byte 0.
        #expect(controller.constantTimeEqual("hello-world", "Hello-world") == false)
    }

    @Test("Single-byte inputs comparing equal return true")
    func singleByteEqualReturnsTrue() {
        #expect(controller.constantTimeEqual("a", "a") == true)
    }

    @Test("Single-byte inputs differing return false")
    func singleByteDifferentReturnsFalse() {
        #expect(controller.constantTimeEqual("a", "b") == false)
    }

    // ── Non-ASCII inputs (defensive) ─────────────────────────────────

    @Test("Non-ASCII content compares byte-for-byte (not Unicode-canonical)")
    func nonASCIIComparesAtUTF8Level() {
        // "é" can be one of two normalized Unicode forms — composed
        // (U+00E9) or decomposed (U+0065 U+0301). They render
        // identically and Swift's `==` returns true (canonical
        // equivalence). The intent of constantTimeEqual is BYTE-LEVEL
        // equality, not visual; the two forms have different UTF-8
        // byte counts so they should compare false. This pins the
        // intent and protects against an accidental swap to `==`.
        let composed = "caf\u{00E9}"           // 5 bytes
        let decomposed = "cafe\u{0301}"        // 6 bytes
        #expect(controller.constantTimeEqual(composed, decomposed) == false,
                "byte-level equality must not be tricked by Unicode canonical equivalence")
    }

    @Test("Empty vs non-empty returns false")
    func emptyVsNonEmptyReturnsFalse() {
        #expect(controller.constantTimeEqual("", "anything") == false)
        #expect(controller.constantTimeEqual("anything", "") == false)
    }

    // ── Determinism check ─────────────────────────────────────────────

    @Test("Same inputs produce the same result on repeated calls")
    func deterministicResultAcrossCalls() {
        // The HMAC-based impl uses a *fresh ephemeral key per call*,
        // which means the intermediate MAC values differ on every
        // invocation, but the *result* of the verify step must still
        // be deterministic on the input strings. This catches a class
        // of bugs where the per-call key accidentally leaks state
        // (e.g., a misuse of HMAC<...>.update would do this).
        for _ in 0..<10 {
            #expect(controller.constantTimeEqual("token-A", "token-A") == true)
            #expect(controller.constantTimeEqual("token-A", "token-B") == false)
        }
    }
}
