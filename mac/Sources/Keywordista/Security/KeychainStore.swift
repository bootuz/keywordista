import Foundation
import Security

/// Typed wrapper over macOS Keychain for the menubar app's two
/// classes of secret:
///   • Provider API tokens (Render, Fly, …) — one per ProviderKind
///     plus owner-account identifier so the user can have multiple
///     accounts per provider.
///   • Per-instance session cookies for the deployed instance's
///     authenticated routes — looked up by Instance.id.
///
/// **Why not store these in instances.json**: that file is plain JSON,
/// world-readable to anything running as the user. A malicious app
/// reading it would get topology data (which deployments exist) but
/// no secrets. Keychain entries require explicit user authorization
/// for non-owning processes.
///
/// **API shape**: throws on failure, returns nil for "not found"
/// (the common case for first-time setup) — distinguishing those
/// at the call site is much cleaner than every caller having to
/// pattern-match OSStatus values.
///
/// **Service naming conventions**:
///   app.keywordista.providers.<kind>  — provider API tokens
///   app.keywordista.sessions          — per-instance session cookies
///   app.keychain.menubar.*            — reserved namespace for future
///                                        per-instance secrets (M5+)
enum KeychainStore {

    // MARK: - Service prefixes

    /// Provider API tokens live under one service per provider so
    /// Keychain Access.app shows them grouped during support.
    private static func providerService(_ kind: ProviderKind) -> String {
        "app.keywordista.providers.\(kind.rawValue)"
    }

    /// One service for all session cookies, keyed by Instance.id as
    /// the account. Lets `wipeAllSessionCookies()` (M5 cleanup hook)
    /// query by service without enumerating instances.
    private static let sessionService = "app.keywordista.sessions"

    // MARK: - Provider tokens

    /// Stores or replaces the API token for a provider, scoped to an
    /// owner-account string (typically the email or owner ID the user
    /// authenticated with — the Keychain entry is identifiable per
    /// account so multiple Render accounts can coexist).
    static func setProviderToken(
        _ token: String,
        kind: ProviderKind,
        account: String
    ) throws {
        try set(
            value: Data(token.utf8),
            service: providerService(kind),
            account: account
        )
    }

    static func providerToken(
        kind: ProviderKind,
        account: String
    ) throws -> String? {
        guard let data = try get(service: providerService(kind), account: account) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func removeProviderToken(
        kind: ProviderKind,
        account: String
    ) throws {
        try delete(service: providerService(kind), account: account)
    }

    // MARK: - Session cookies

    /// Stores a session cookie value (just the cookie's string value,
    /// not a full Set-Cookie header) for the given instance. Used by
    /// the "Open dashboard in browser" deeplink flow and the in-app
    /// API calls against the deployed instance's authenticated routes.
    static func setSessionCookie(
        _ cookie: String,
        instanceID: UUID
    ) throws {
        try set(
            value: Data(cookie.utf8),
            service: sessionService,
            account: instanceID.uuidString
        )
    }

    static func sessionCookie(instanceID: UUID) throws -> String? {
        guard let data = try get(service: sessionService, account: instanceID.uuidString) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func removeSessionCookie(instanceID: UUID) throws {
        try delete(service: sessionService, account: instanceID.uuidString)
    }

    // MARK: - Lower-level SecItem primitives
    //
    // The set/get/delete trio collapses the SecItem* C API surface into
    // throws-on-real-failure + nil-on-not-found. Every variant matches
    // a tuple of (kSecClassGenericPassword, kSecAttrService, kSecAttrAccount)
    // — the three-field identity Keychain uses to find an item.
    //
    // Why generic password (not internet password): we're storing
    // arbitrary tokens + cookies, not a URL/realm-scoped credential.
    // Generic password is the canonical class for app-managed secrets.

    /// Idempotent "set" — delete-then-add eliminates the duplicate-item
    /// error path. The two operations aren't atomic at the Keychain
    /// level, but a concurrent reader could only see "not present" for
    /// a microsecond between the two calls — acceptable for this use
    /// case (the menubar app doesn't run multi-instance, so contention
    /// is theoretical).
    private static func set(value: Data, service: String, account: String) throws {
        try? delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            // Accessible only when the device is unlocked and only by
            // this device — the most restrictive accessibility class
            // appropriate for a credential. kSecAttrAccessibleAfterFirstUnlock
            // would let the keychain be read after boot before user
            // login; we don't want that.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status, operation: "add")
        }
    }

    private static func get(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status, operation: "copy")
        }
        return result as? Data
    }

    private static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // "Not found" on delete is success — the caller wanted it gone.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status, operation: "delete")
        }
    }
}

// MARK: - Errors

enum KeychainError: Error, CustomStringConvertible {
    /// Wraps a raw OSStatus. We don't try to translate every value to
    /// a typed case — the OSStatus codespace is huge and only a few
    /// codes are actionable. Callers that need to distinguish "user
    /// cancelled the auth prompt" (errSecUserCanceled) from "duplicate
    /// item" (errSecDuplicateItem) can switch on the code; everyone
    /// else just surfaces the message.
    case osStatus(OSStatus, operation: String)

    var description: String {
        switch self {
        case .osStatus(let code, let op):
            let msg = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return "Keychain \(op) failed: \(msg)"
        }
    }
}
