import CryptoKit
import Foundation

/// Pure functions for the three secrets the cockpit generates locally
/// before a deploy:
///
///   1. `generateEncryptionKey()` — 32 random bytes for the deployed
///      instance's KEYWORDISTA_ENCRYPTION_KEY (encrypts ASC `.p8`,
///      ASA secret, future Web Push keys at rest in the deployed DB).
///   2. `generateAdminPassword()` — 24-char human-readable password
///      shown to the user once and copied to clipboard for them to
///      save in a password manager.
///   3. `bcryptHash(_:cost:)` — hashes #2 locally so the plaintext
///      never crosses the wire to the provider.
///
/// **Security keystone**: the plaintext admin password EXISTS ONLY on
/// the user's Mac. It's in memory for ~30s between generation and
/// clipboard copy, never persisted, never sent over HTTPS to anyone.
/// The provider's API receives only the bcrypt hash via
/// KEYWORDISTA_ADMIN_PASSWORD_HASH env var. Render's database, Render's
/// API logs, an over-the-shoulder screenshot of a Render env-var
/// dialog — none of them ever see the plaintext.
enum SecretsGenerator {

    /// 32 cryptographically-secure random bytes, hex-encoded. Format
    /// matches what KEYWORDISTA_ENCRYPTION_KEY's parser
    /// (Parsers.hexBytes(expectedBytes: 32) in EnvVarManifest.swift)
    /// expects: 64 lowercase hex chars, no separators.
    ///
    /// Uses CryptoKit's SymmetricKey which delegates to the system's
    /// secure random source (SecRandomCopyBytes on Darwin). Never
    /// returns the same bytes twice in this universe's lifetime.
    static func generateEncryptionKey() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// 24-char password from a curated charset: A-Z, a-z, 0-9 with
    /// ambiguous characters (0/O, 1/l/I) removed. The alphabet is
    /// deliberately conservative — no shell-special bytes (`'", $, `,
    /// ;, &), no whitespace. The user might be copying this through
    /// clipboard tooling that mangles some characters, so "safe across
    /// every paste surface" wins over "maximum entropy per byte."
    ///
    /// 24 chars × ~5.78 bits/char (after de-ambiguating the alphabet
    /// down to 55 chars) ≈ 138 bits of entropy — well above the 80-bit
    /// threshold for "doesn't matter if it ends up in a leaked
    /// database dump."
    static func generateAdminPassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")
        var password = ""
        for _ in 0..<24 {
            // Int.random uses SystemRandomNumberGenerator on Darwin,
            // which is cryptographically secure (arc4random under the
            // hood). The bias from `% alphabet.count` is negligible at
            // these ratios (UInt64.max is a colossal multiple of 55).
            let idx = Int.random(in: 0..<alphabet.count)
            password.append(alphabet[idx])
        }
        return password
    }

    /// Bcrypts the password at the given cost factor via the system's
    /// `/usr/sbin/htpasswd` binary. Produces a `$2y$<cost>$<salt><hash>`
    /// string compatible with Vapor's `Bcrypt.verify` on the backend
    /// (Vapor accepts $2a$/$2b$/$2y$ interchangeably — algorithmically
    /// identical, only metadata differs).
    ///
    /// **Why shell out to htpasswd instead of a Swift bcrypt library**:
    /// (1) htpasswd has been part of every macOS install since the
    /// Apache 1.3 era — zero new dependency footprint; (2) avoids
    /// writing or auditing bcrypt crypto code in Swift; (3) Vapor's
    /// Bcrypt is the natural other choice but pulls 60MB+ of server
    /// dependencies into the menubar app for one hash; (4) standalone
    /// Swift bcrypt SPM packages are sparse and dormant.
    ///
    /// **Sandbox caveat**: `Process` calls require the
    /// `com.apple.security.app-sandbox = false` entitlement (current
    /// state) OR a sandbox exception. The menubar app isn't currently
    /// sandboxed; if it becomes sandboxed, this function needs a
    /// replacement implementation. Documented at the call site so
    /// future-us doesn't get blindsided.
    ///
    /// **Cost choice**: 12 matches the server's manifest default
    /// (EnvVarManifest's bcryptCost). Cost 12 takes ~250ms on Render
    /// Starter ($7/mo tier) — slow enough that brute-forcing a leaked
    /// hash is prohibitive, fast enough that login doesn't feel
    /// sluggish.
    ///
    /// **Throws** SecretsGeneratorError on htpasswd invocation
    /// failure (binary missing, non-zero exit, malformed output). The
    /// deploy wizard surfaces these to the user as "couldn't prepare
    /// the admin password — file a bug" rather than fatal-erroring.
    static func bcryptHash(_ password: String, cost: Int = 12) throws -> String {
        // htpasswd -nbB -C <cost> <user> <password>
        //   -n      print to stdout instead of writing to a file
        //   -b      take password from CLI (not interactive prompt)
        //   -B      use bcrypt
        //   -C      cost factor (4..17 on macOS htpasswd)
        // The "user" is throwaway — we extract the hash after the
        // colon. Use a fixed dummy username so the output is stable.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/htpasswd")
        process.arguments = ["-nbB", "-C", "\(cost)", "x", password]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SecretsGeneratorError.htpasswdLaunchFailed(error)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            throw SecretsGeneratorError.htpasswdFailed(
                exitCode: process.terminationStatus,
                stderr: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Output shape: "x:$2y$12$abc...". Split on first ':' to
        // extract the hash. If the shape's wrong something's catastrophic.
        guard let colonIdx = raw.firstIndex(of: ":") else {
            throw SecretsGeneratorError.htpasswdMalformedOutput(raw)
        }
        let hash = String(raw[raw.index(after: colonIdx)...])
        guard hash.hasPrefix("$2") else {
            throw SecretsGeneratorError.htpasswdMalformedOutput(raw)
        }
        return hash
    }
}

enum SecretsGeneratorError: Error, CustomStringConvertible {
    case htpasswdLaunchFailed(Error)
    case htpasswdFailed(exitCode: Int32, stderr: String)
    case htpasswdMalformedOutput(String)

    var description: String {
        switch self {
        case .htpasswdLaunchFailed(let e):
            return "couldn't launch /usr/sbin/htpasswd: \(e.localizedDescription)"
        case .htpasswdFailed(let code, let stderr):
            return "htpasswd exited \(code): \(stderr)"
        case .htpasswdMalformedOutput(let raw):
            return "htpasswd produced unexpected output: '\(raw)'"
        }
    }
}
