import Crypto
import Foundation

/// AES-GCM-256 authenticated encryption with a single static key.
///
/// Used to encrypt operator credentials at rest in the database:
///   • App Store Connect `.p8` private key
///   • Apple Search Ads client secret
///   • (M1+) bcrypt-hashed admin passwords' pepper, if any
///   • (post-v1) Web Push VAPID private key
///
/// Sealed format follows Apple's `AES.GCM.SealedBox.combined`:
///   `[12-byte nonce] [ciphertext] [16-byte authentication tag]`
///
/// This is the standard recommendation for application-layer crypto on
/// top of an externally-managed key; the GCM auth tag catches
/// tampering, the nonce is generated per call so identical plaintexts
/// produce different ciphertexts, and the format is self-describing
/// (no separate IV column needed in the DB).
///
/// Key management lives in `EncryptionKeyResolver`; this type only
/// cares about the bytes.
public struct SecretBox: Sendable {

    public let key: SymmetricKey

    /// Construct with a `SymmetricKey`. In production this comes from
    /// `EncryptionKeyResolver.resolve(mode:explicit:)`; tests use
    /// arbitrary fixture keys.
    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Encrypt `plaintext`. The returned `Data` is the full sealed
    /// envelope (nonce + ciphertext + tag); store it verbatim in the DB.
    public func seal(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        // `combined` is `nil` only when a custom nonce was used and the
        // sealed box can't be reassembled; we never pass a custom nonce,
        // so this guard is defense-in-depth, not an expected branch.
        guard let combined = sealed.combined else {
            throw SecretBoxError.sealingProducedNoCombinedForm
        }
        return combined
    }

    /// Decrypt a sealed envelope produced by `seal`. Throws if the
    /// ciphertext is truncated, tampered with, or was sealed under a
    /// different key.
    public func open(_ envelope: Data) throws -> Data {
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: envelope)
        } catch {
            // CryptoKit throws a structureless error for shorter-than-
            // header inputs; remap so callers get a clear message.
            throw SecretBoxError.envelopeMalformed(reason: "\(error)")
        }
        return try AES.GCM.open(sealed, using: key)
    }

    /// Convenience for the common "string in, string out" call shape
    /// used by ASC `.p8` content (PEM) and ASA client secret.
    public func sealString(_ plaintext: String) throws -> Data {
        try seal(Data(plaintext.utf8))
    }

    public func openString(_ envelope: Data) throws -> String {
        let data = try open(envelope)
        guard let s = String(data: data, encoding: .utf8) else {
            throw SecretBoxError.openedBytesNotUTF8
        }
        return s
    }
}

public enum SecretBoxError: Error, CustomStringConvertible, Equatable {
    case sealingProducedNoCombinedForm
    case envelopeMalformed(reason: String)
    case openedBytesNotUTF8

    public var description: String {
        switch self {
        case .sealingProducedNoCombinedForm:
            return "AES-GCM seal produced no combined form (should never happen with default nonce)"
        case .envelopeMalformed(let reason):
            return "sealed envelope is malformed or truncated: \(reason)"
        case .openedBytesNotUTF8:
            return "decrypted bytes are not valid UTF-8 (caller used sealString but the value isn't a string)"
        }
    }
}
