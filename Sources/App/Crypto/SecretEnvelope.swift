import Foundation

/// Storage-format wrapper for encrypted-at-rest credentials.
///
/// Encoded as `enc:v1:<base64-of-sealed-bytes>` so the Setting
/// table's plain `String` value column can hold ciphertext. The
/// magic prefix serves two purposes:
///
///   1. **Detect "already encrypted"** at read time. The M1.9
///      migration normalizes pre-existing plaintext rows into
///      this format; before it runs (or for any row that escaped
///      it), reads need to distinguish encrypted vs plaintext
///      to decide whether to attempt decryption.
///
///   2. **Versioned format**. The `v1` tag means a future cipher
///      change (e.g. switching from AES-GCM to ChaCha20-Poly1305,
///      or rotating to a different key-derivation scheme) is
///      SemVer-additive — old `enc:v1:` envelopes keep decrypting,
///      new writes emit `enc:v2:`, and a future migration converts
///      old to new at its own pace.
///
/// Pure functions; no SecretBox state outside what's passed in.
/// Tested in isolation; SettingsService composes these calls.
enum SecretEnvelope {

    /// Versioned magic prefix. **Changing this value is a
    /// data-migration event** — every existing encrypted row in
    /// every operator's DB has it embedded. Append a new "vN"
    /// version constant instead.
    static let v1Prefix = "enc:v1:"

    // MARK: - Detection

    /// `true` if `stored` looks like a SecretEnvelope-wrapped
    /// value (any supported version). Doesn't validate the
    /// ciphertext — just checks the prefix.
    static func isWrapped(_ stored: String) -> Bool {
        stored.hasPrefix(v1Prefix)
    }

    // MARK: - Wrap

    /// Seal `plaintext` and return an `enc:v1:...` string suitable
    /// for storage in the Setting table's value column.
    ///
    /// Non-deterministic by construction (fresh nonce per call) —
    /// the same plaintext wrapped twice produces different stored
    /// strings. Tests pin this so a future "stable encryption for
    /// caching" refactor would surface as a deliberate breaking
    /// change.
    static func wrap(_ plaintext: String, with box: SecretBox) throws -> String {
        let sealed = try box.sealString(plaintext)
        return v1Prefix + sealed.base64EncodedString()
    }

    // MARK: - Unwrap

    /// Decode `stored` back to plaintext.
    ///
    /// Backward-compatibility behavior — if `stored` does NOT
    /// have the `enc:v1:` prefix, it's treated as **legacy
    /// plaintext** and returned as-is. This is what makes the
    /// M1.9 migration's "encrypt every plaintext row, idempotent"
    /// dance work: a read between migration rollout and the row
    /// being touched returns the right answer either way.
    ///
    /// (Once M1.9 has run, all secret-shaped rows should have the
    /// prefix; this path becomes essentially dead code. It stays
    /// for defense in depth.)
    static func unwrap(_ stored: String, with box: SecretBox) throws -> String {
        guard stored.hasPrefix(v1Prefix) else {
            return stored
        }
        let b64 = String(stored.dropFirst(v1Prefix.count))
        guard let envelope = Data(base64Encoded: b64) else {
            throw SecretEnvelopeError.malformedBase64
        }
        return try box.openString(envelope)
    }
}

// MARK: - Errors

enum SecretEnvelopeError: Error, CustomStringConvertible, Equatable {
    case malformedBase64

    var description: String {
        switch self {
        case .malformedBase64:
            return "stored secret has the enc:v1: prefix but the payload isn't valid base64"
        }
    }
}
