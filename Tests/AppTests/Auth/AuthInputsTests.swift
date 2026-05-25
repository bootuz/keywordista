@testable import App
import Foundation
import Testing
import Vapor

@Suite("AuthInputs")
struct AuthInputsTests {

    // ── Email ────────────────────────────────────────────────────────

    @Suite("validateEmail")
    struct EmailTests {

        @Test("Accepts a well-formed email + returns the normalized form")
        func happyPath() throws {
            let out = try AuthInputs.validateEmail("  You@Studio.Com  ")
            #expect(out == "you@studio.com")
        }

        @Test("Rejects empty / whitespace-only input")
        func rejectsEmpty() {
            for raw in ["", " ", "   \n\t"] {
                #expect(throws: (any Error).self) {
                    _ = try AuthInputs.validateEmail(raw)
                }
            }
        }

        @Test("Rejects strings without @ or without .")
        func rejectsMalformed() {
            for raw in ["no-at-sign", "no-dot@example", "trailing@", "@leading.com"] {
                #expect(throws: (any Error).self) {
                    _ = try AuthInputs.validateEmail(raw)
                }
            }
        }

        @Test("Validation error is Abort with .badRequest status")
        func errorIsTyped() {
            do {
                _ = try AuthInputs.validateEmail("not-an-email")
                Issue.record("expected throw")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
                #expect(abort.reason.contains("email"))
            } catch {
                Issue.record("expected Abort, got \(error)")
            }
        }
    }

    // ── Password ─────────────────────────────────────────────────────

    @Suite("validatePassword")
    struct PasswordTests {

        @Test("Accepts passwords at or above the minimum length")
        func acceptsLong() throws {
            try AuthInputs.validatePassword("12345678")     // exactly 8
            try AuthInputs.validatePassword("a very long password")
            try AuthInputs.validatePassword("☕☕☕☕☕☕☕☕")    // emoji count too
        }

        @Test("Rejects passwords shorter than the minimum")
        func rejectsShort() {
            for raw in ["", "a", "1234567"] {
                #expect(throws: (any Error).self) {
                    try AuthInputs.validatePassword(raw)
                }
            }
        }

        @Test("Does NOT normalize whitespace (padding is part of the password)")
        func preservesPadding() throws {
            // A password like '  hunter2  ' is intentionally distinct
            // from 'hunter2'. Silently stripping would lock the user
            // out of an account they created with padding.
            try AuthInputs.validatePassword("  hunter2  ")  // 12 chars with spaces
        }

        @Test("Counts grapheme clusters not bytes (matches user mental model)")
        func graphemeCount() {
            // 'café' is 4 grapheme clusters but might be 5 UTF-8 bytes
            // depending on normalization. The check uses .count which
            // returns grapheme count → correct.
            #expect("café1234".count == 8)
            #expect(throws: Never.self) {
                try AuthInputs.validatePassword("café1234")
            }
        }
    }

    // ── Invite token ─────────────────────────────────────────────────

    @Suite("validateInviteToken")
    struct InviteTokenTests {

        @Test("Accepts a real-shaped 43-char base64url token")
        func acceptsRealToken() throws {
            // Borrow the live generator so we test the contract end-to-end.
            let token = Invite.generateToken()
            let out = try AuthInputs.validateInviteToken(token)
            #expect(out == token)
        }

        @Test("Rejects wrong-length tokens")
        func rejectsLength() {
            for raw in ["", "abc", String(repeating: "a", count: 42), String(repeating: "a", count: 44)] {
                #expect(throws: (any Error).self) {
                    _ = try AuthInputs.validateInviteToken(raw)
                }
            }
        }

        @Test("Rejects tokens with non-base64url characters")
        func rejectsBadChars() {
            // 43 chars but containing illegal '+' (base64 standard, not base64url).
            let bad = "+" + String(repeating: "a", count: 42)
            #expect(throws: (any Error).self) {
                _ = try AuthInputs.validateInviteToken(bad)
            }
        }

        @Test("Trims leading + trailing whitespace before validating")
        func trimsWhitespace() throws {
            let token = Invite.generateToken()
            let padded = "  \n\(token)\t  "
            let out = try AuthInputs.validateInviteToken(padded)
            #expect(out == token)
        }
    }
}
