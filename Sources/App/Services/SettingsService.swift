import Foundation

// Typed credential structs — the boundary between the generic key/value store
// and the integrations that consume them.

struct ASCCredentials: Sendable, Equatable {
    let keyId: String
    let issuerId: String
    let privateKey: String  // The .p8 contents, including BEGIN/END lines.
}

struct ASACredentials: Sendable, Equatable {
    let clientId: String
    let clientSecret: String
    let orgId: String?
}

// Storage-level status descriptors. These are what the API returns to the
// settings UI — they tell you which fields are set without ever echoing the
// secret material back to the browser.
//
// `configured` is a STORED property even though it's derived: Swift's
// synthesized Codable encoder only emits stored properties, so making it
// computed would silently drop the field on the wire (the SPA's "Not
// connected" indicator depends on it).
struct ASCStatus: Codable, Sendable, Equatable {
    let keyId: String?
    let issuerId: String?
    let hasPrivateKey: Bool
    let configured: Bool

    init(keyId: String?, issuerId: String?, hasPrivateKey: Bool) {
        self.keyId = keyId
        self.issuerId = issuerId
        self.hasPrivateKey = hasPrivateKey
        self.configured = keyId != nil && issuerId != nil && hasPrivateKey
    }
}

struct ASAStatus: Codable, Sendable, Equatable {
    let clientId: String?
    let orgId: String?
    let hasClientSecret: Bool
    let configured: Bool

    init(clientId: String?, orgId: String?, hasClientSecret: Bool) {
        self.clientId = clientId
        self.orgId = orgId
        self.hasClientSecret = hasClientSecret
        self.configured = clientId != nil && hasClientSecret
    }
}

protocol SettingsServiceProtocol: Sendable {
    func getASCStatus() async throws -> ASCStatus
    func getASCCredentials() async throws -> ASCCredentials?
    func setASCCredentials(_ creds: ASCCredentials) async throws
    func clearASCCredentials() async throws

    func getASAStatus() async throws -> ASAStatus
    func getASACredentials() async throws -> ASACredentials?
    func setASACredentials(_ creds: ASACredentials) async throws
    func clearASACredentials() async throws
}

struct SettingsService: SettingsServiceProtocol {
    let repository: any SettingsRepositoryProtocol

    /// Encryption-at-rest for credential-shaped values (M1.9). Wraps
    /// asc.privateKey + asa.clientSecret transparently on write,
    /// unwraps on read. Plain-shaped keys (asc.keyId, asa.clientId,
    /// asa.orgId, asc.issuerId) bypass it — they're not secrets.
    let secretBox: SecretBox

    // ── Key names ────────────────────────────────────────────────────────────
    // String constants live here (not at file scope) so the only place that
    // knows about storage key names is the service.
    enum Keys {
        static let ascKeyId = "asc.keyId"
        static let ascIssuerId = "asc.issuerId"
        static let ascPrivateKey = "asc.privateKey"
        static let asaClientId = "asa.clientId"
        static let asaClientSecret = "asa.clientSecret"
        static let asaOrgId = "asa.orgId"

        static let asc = [ascKeyId, ascIssuerId, ascPrivateKey]
        static let asa = [asaClientId, asaClientSecret, asaOrgId]

        /// The subset of storage keys whose values are credential-
        /// shaped and must be encrypted at rest. The M1.9 migration
        /// reads from this same list so it normalizes exactly the
        /// rows the service would write encrypted.
        static let secretShaped: Set<String> = [
            ascPrivateKey,
            asaClientSecret,
        ]
    }

    // ── ASC ──────────────────────────────────────────────────────────────────

    func getASCStatus() async throws -> ASCStatus {
        let values = try await repository.getMany(keys: Keys.asc)
        // hasPrivateKey is a "row exists and non-empty" check — we
        // don't need to decrypt the value just to know it's present.
        return ASCStatus(
            keyId: values[Keys.ascKeyId],
            issuerId: values[Keys.ascIssuerId],
            hasPrivateKey: values[Keys.ascPrivateKey]?.isEmpty == false
        )
    }

    func getASCCredentials() async throws -> ASCCredentials? {
        let values = try await repository.getMany(keys: Keys.asc)
        guard
            let keyId = values[Keys.ascKeyId], !keyId.isEmpty,
            let issuerId = values[Keys.ascIssuerId], !issuerId.isEmpty,
            let storedKey = values[Keys.ascPrivateKey], !storedKey.isEmpty
        else { return nil }
        // M1.9 envelope unwrap: legacy plaintext rows pass through
        // unchanged (see SecretEnvelope.unwrap header for why).
        let privateKey = try SecretEnvelope.unwrap(storedKey, with: secretBox)
        return ASCCredentials(keyId: keyId, issuerId: issuerId, privateKey: privateKey)
    }

    func setASCCredentials(_ creds: ASCCredentials) async throws {
        try await repository.set(Keys.ascKeyId, value: creds.keyId)
        try await repository.set(Keys.ascIssuerId, value: creds.issuerId)
        let sealed = try SecretEnvelope.wrap(creds.privateKey, with: secretBox)
        try await repository.set(Keys.ascPrivateKey, value: sealed)
    }

    func clearASCCredentials() async throws {
        for key in Keys.asc { try await repository.delete(key) }
    }

    // ── ASA ──────────────────────────────────────────────────────────────────

    func getASAStatus() async throws -> ASAStatus {
        let values = try await repository.getMany(keys: Keys.asa)
        return ASAStatus(
            clientId: values[Keys.asaClientId],
            orgId: values[Keys.asaOrgId],
            hasClientSecret: values[Keys.asaClientSecret]?.isEmpty == false
        )
    }

    func getASACredentials() async throws -> ASACredentials? {
        let values = try await repository.getMany(keys: Keys.asa)
        guard
            let clientId = values[Keys.asaClientId], !clientId.isEmpty,
            let storedSecret = values[Keys.asaClientSecret], !storedSecret.isEmpty
        else { return nil }
        // M1.9 envelope unwrap — same legacy-plaintext pass-through
        // as the ASC path.
        let clientSecret = try SecretEnvelope.unwrap(storedSecret, with: secretBox)
        return ASACredentials(
            clientId: clientId,
            clientSecret: clientSecret,
            orgId: values[Keys.asaOrgId]
        )
    }

    func setASACredentials(_ creds: ASACredentials) async throws {
        try await repository.set(Keys.asaClientId, value: creds.clientId)
        let sealed = try SecretEnvelope.wrap(creds.clientSecret, with: secretBox)
        try await repository.set(Keys.asaClientSecret, value: sealed)
        if let orgId = creds.orgId, !orgId.isEmpty {
            try await repository.set(Keys.asaOrgId, value: orgId)
        } else {
            try await repository.delete(Keys.asaOrgId)
        }
    }

    func clearASACredentials() async throws {
        for key in Keys.asa { try await repository.delete(key) }
    }
}
