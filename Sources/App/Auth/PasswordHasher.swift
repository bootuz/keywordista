import Foundation
import Vapor

/// Bcrypt-backed password hashing for the auth layer.
///
/// Wraps Vapor's built-in `Bcrypt` API with three things it doesn't
/// give us out of the box:
///
///   1. **Cost configurable from the env-var manifest.** `KEYWORDISTA_
///      BCRYPT_COST` defaults to 12 and is read by configure.swift
///      at boot. Adjusting per-deployment (e.g. cost 14 for a more
///      paranoid operator) is one env-var flip — no code change.
///
///   2. **Init-time validation of the cost range.** Bcrypt rejects
///      anything below 4 or above 31 at hash time; we surface that
///      at boot so misconfiguration shows up in the deploy log,
///      not at first user signup.
///
///   3. **CPU-bound work off the EventLoop.** Bcrypt at cost 12 is
///      ~250 ms of pure compute. If we did that on the EventLoop
///      thread, every other request blocks behind it. The async
///      methods detach the work to a background thread so EventLoop
///      keeps serving while the hash churns.
///
/// Construction is cheap (just stores the cost); inject one instance
/// via the DI container and reuse it for every hash/verify in the
/// auth layer.
public struct PasswordHasher: Sendable {

    public let cost: Int

    public init(cost: Int) throws {
        // Bcrypt's own bounds. Cost 4 is the minimum the spec allows;
        // cost 31 is the maximum representable in a single round
        // counter. Practical operators stay in 10..14.
        guard (4...31).contains(cost) else {
            throw PasswordHasherError.costOutOfRange(got: cost)
        }
        self.cost = cost
    }

    // MARK: Hashing

    /// Compute a fresh bcrypt hash for `password`. Detached onto a
    /// background thread so the calling EventLoop stays free.
    public func hash(_ password: String) async throws -> String {
        let cost = self.cost
        return try await Task.detached(priority: .userInitiated) {
            do {
                return try Bcrypt.hash(password, cost: cost)
            } catch {
                throw PasswordHasherError.hashingFailed(reason: "\(error)")
            }
        }.value
    }

    /// Verify `password` against a previously-computed `hash`. Returns
    /// `false` on mismatch; throws on a malformed hash string so the
    /// caller can distinguish "wrong password" from "corrupt data".
    ///
    /// Detached for the same reason `hash` is: bcrypt verify is the
    /// same ~250 ms compute as bcrypt hash.
    public func verify(_ password: String, against hash: String) async throws -> Bool {
        return try await Task.detached(priority: .userInitiated) {
            do {
                return try Bcrypt.verify(password, created: hash)
            } catch {
                // Bcrypt.verify throws on malformed hash strings (wrong
                // prefix, wrong length, corrupt salt). Remap so the
                // auth layer sees a typed error.
                throw PasswordHasherError.malformedHash(reason: "\(error)")
            }
        }.value
    }
}

// MARK: - Errors

public enum PasswordHasherError: Error, CustomStringConvertible, Equatable {
    case costOutOfRange(got: Int)
    case hashingFailed(reason: String)
    case malformedHash(reason: String)

    public var description: String {
        switch self {
        case .costOutOfRange(let got):
            return "bcrypt cost must be in 4...31, got \(got)"
        case .hashingFailed(let reason):
            return "bcrypt hash failed: \(reason)"
        case .malformedHash(let reason):
            return "bcrypt hash is malformed: \(reason)"
        }
    }
}
