import Crypto
import Foundation
#if os(macOS)
import IOKit
#endif

/// Boot-time resolution of the symmetric encryption key that the
/// `SecretBox` uses to encrypt operator credentials at rest.
///
/// Resolution rule (plan §4.3):
///
///   • If `KEYWORDISTA_ENCRYPTION_KEY` is set, use it. The manifest's
///     `Parsers.hexBytes(expectedBytes: 32)` has already validated it's
///     exactly 32 bytes; we just wrap it as a `SymmetricKey`.
///
///   • Otherwise:
///       - In **server** mode → boot fails. The manifest declares this
///         var as `requiredIn: .onlyInModes([.server])` so missing-var
///         validation in `Manifest.bootstrap` is what actually catches
///         this; the explicit throw here is defense in depth (callers
///         could in principle skip manifest validation, e.g. in tests).
///       - In **local** mode → derive deterministically from the Mac's
///         hardware UUID (`IOPlatformUUID`). Same Mac → same key →
///         same DB stays decryptable across restarts. Different Mac →
///         different key, which is exactly what you want for "don't
///         carry your secrets to someone else's Mac."
///
/// The local-mode derivation is intentionally not exposed as a "save
/// and reuse" flow — there's no key file, no Keychain entry, no
/// user-visible secret. The key IS the Mac. Reinstalling macOS keeps
/// the same `IOPlatformUUID`; replacing the Mac generates a new one
/// (and existing encrypted secrets in a copied DB become unreadable,
/// which is correct: an attacker who exfiltrates the SQLite file to
/// their own machine can't open the .p8).
public enum EncryptionKeyResolver {

    public static func resolve(
        mode: RuntimeMode,
        explicit: Data?
    ) throws -> SymmetricKey {
        if let raw = explicit {
            // Parser already validated 32 bytes; re-check defensively
            // because the parser could be bypassed in tests.
            guard raw.count == 32 else {
                throw EncryptionKeyError.wrongKeySize(got: raw.count)
            }
            return SymmetricKey(data: raw)
        }

        switch mode {
        case .server:
            // The manifest's requiredIn check should have surfaced this
            // earlier with a friendlier message. We throw too so any
            // alternate boot path (e.g. test code skipping bootstrap)
            // still fails closed.
            throw EncryptionKeyError.missingInServerMode

        case .local:
            return try deriveFromMachineID()
        }
    }

    // MARK: - Local-mode derivation

    /// SHA-256 of the Mac's `IOPlatformUUID`, taken as 32 raw bytes.
    /// Deterministic across runs on the same Mac.
    private static func deriveFromMachineID() throws -> SymmetricKey {
        #if os(macOS)
        let uuid = try MachineUUID.fetch()
        let digest = SHA256.hash(data: Data(uuid.utf8))
        return SymmetricKey(data: Data(digest))
        #else
        // Local mode on Linux is not a supported configuration: the
        // macOS app is the only thing that spawns the local-mode
        // binary, and it only runs on macOS. If we somehow ended up
        // here (test on Linux CI?), fail loudly.
        throw EncryptionKeyError.localModeUnsupportedOnPlatform
        #endif
    }
}

public enum EncryptionKeyError: Error, CustomStringConvertible, Equatable {
    case missingInServerMode
    case localModeUnsupportedOnPlatform
    case wrongKeySize(got: Int)
    case machineUUIDUnavailable(reason: String)

    public var description: String {
        switch self {
        case .missingInServerMode:
            return "KEYWORDISTA_ENCRYPTION_KEY is required in server mode (64 hex chars / 32 bytes)"
        case .localModeUnsupportedOnPlatform:
            return "local-mode encryption-key derivation is only supported on macOS"
        case .wrongKeySize(let got):
            return "encryption key must be exactly 32 bytes, got \(got)"
        case .machineUUIDUnavailable(let reason):
            return "could not read IOPlatformUUID: \(reason)"
        }
    }
}

// MARK: - MachineUUID
//
// Tiny wrapper around the IOKit incantation to fetch the Mac's hardware
// UUID. macOS-only by construction; the `#if os(macOS)` in the resolver
// keeps this from ever being called elsewhere.

#if os(macOS)
enum MachineUUID {
    static func fetch() throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else {
            throw EncryptionKeyError.machineUUIDUnavailable(
                reason: "IOServiceGetMatchingService returned 0 for IOPlatformExpertDevice"
            )
        }
        defer { IOObjectRelease(service) }

        let cf = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )
        guard let unmanaged = cf else {
            throw EncryptionKeyError.machineUUIDUnavailable(
                reason: "IORegistryEntryCreateCFProperty returned nil for IOPlatformUUID"
            )
        }

        guard let uuid = unmanaged.takeRetainedValue() as? String, !uuid.isEmpty else {
            throw EncryptionKeyError.machineUUIDUnavailable(
                reason: "IOPlatformUUID property was not a non-empty String"
            )
        }
        return uuid
    }
}
#endif
