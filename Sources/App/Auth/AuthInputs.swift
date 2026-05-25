import Foundation
import Vapor

/// Input validation for the auth endpoints.
///
/// Pulled out of AuthController so the validation logic is unit-
/// testable in isolation (the existing codebase pattern is "test
/// pure functions, not Vapor handlers" — full HTTP integration
/// coverage lives in M1.12). Each function throws `Abort` so the
/// controller's call sites are one-liners and Vapor surfaces the
/// appropriate HTTP error automatically.
enum AuthInputs {

    /// Minimum password length. **NIST SP 800-63B** modern guidance:
    /// length matters more than character-class complexity, so we
    /// enforce a length floor and skip the "must contain uppercase
    /// + digit + symbol" theater that famously pushes users toward
    /// `Password1!`. Configurable later via env if a paranoid
    /// operator wants 12 / 16 / etc.
    static let passwordMinLength = 8

    // MARK: - Email

    /// Normalizes (lowercased + trimmed) and minimally validates an
    /// email. Same rules as User.email's init-time normalization;
    /// duplicated here so the validation can surface a typed Abort
    /// at the request-decode layer rather than letting a malformed
    /// email reach the User row.
    static func validateEmail(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw Abort(.badRequest, reason: "email is required")
        }
        // Intentionally permissive: catch typos (no `@`, no `.`,
        // leading/trailing `@`) without trying to be RFC 5321.
        // Full validation belongs in the email-delivery step
        // (which we don't have in v1 — invites are link-based).
        guard trimmed.contains("@"),
              trimmed.contains("."),
              !trimmed.hasPrefix("@"),
              !trimmed.hasSuffix("@") else {
            throw Abort(.badRequest, reason: "email is not a valid address")
        }
        return trimmed
    }

    // MARK: - Password

    /// Length check only. **We do NOT normalize whitespace** — a
    /// password like `"  hunter2  "` is a different password from
    /// `"hunter2"`, and silently stripping would lock the user out
    /// of an account they intentionally created with padding.
    static func validatePassword(_ raw: String) throws {
        // Count user-perceived characters (grapheme clusters), not
        // UTF-8 bytes. "café" is 4 characters, not 5; emoji compounds
        // count as one. Matches what every human means by "length".
        guard raw.count >= passwordMinLength else {
            throw Abort(.badRequest, reason: "password must be at least \(passwordMinLength) characters")
        }
    }

    // MARK: - Invite token

    /// Pin to the same shape AuthSession + Invite generate (43-char
    /// base64url). Catches obviously-malformed tokens at the
    /// decode layer with a clearer error than the DB miss would
    /// produce.
    static func validateInviteToken(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 43 else {
            throw Abort(.badRequest, reason: "invite token must be 43 characters")
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else {
            throw Abort(.badRequest, reason: "invite token contains invalid characters")
        }
        return trimmed
    }
}
