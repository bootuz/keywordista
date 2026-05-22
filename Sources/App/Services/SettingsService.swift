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

    // ── Key names ────────────────────────────────────────────────────────────
    // String constants live here (not at file scope) so the only place that
    // knows about storage key names is the service.
    private enum Keys {
        static let ascKeyId = "asc.keyId"
        static let ascIssuerId = "asc.issuerId"
        static let ascPrivateKey = "asc.privateKey"
        static let asaClientId = "asa.clientId"
        static let asaClientSecret = "asa.clientSecret"
        static let asaOrgId = "asa.orgId"

        static let asc = [ascKeyId, ascIssuerId, ascPrivateKey]
        static let asa = [asaClientId, asaClientSecret, asaOrgId]
    }

    // ── ASC ──────────────────────────────────────────────────────────────────

    func getASCStatus() async throws -> ASCStatus {
        let values = try await repository.getMany(keys: Keys.asc)
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
            let privateKey = values[Keys.ascPrivateKey], !privateKey.isEmpty
        else { return nil }
        return ASCCredentials(keyId: keyId, issuerId: issuerId, privateKey: privateKey)
    }

    func setASCCredentials(_ creds: ASCCredentials) async throws {
        try await repository.set(Keys.ascKeyId, value: creds.keyId)
        try await repository.set(Keys.ascIssuerId, value: creds.issuerId)
        try await repository.set(Keys.ascPrivateKey, value: creds.privateKey)
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
            let clientSecret = values[Keys.asaClientSecret], !clientSecret.isEmpty
        else { return nil }
        return ASACredentials(
            clientId: clientId,
            clientSecret: clientSecret,
            orgId: values[Keys.asaOrgId]
        )
    }

    func setASACredentials(_ creds: ASACredentials) async throws {
        try await repository.set(Keys.asaClientId, value: creds.clientId)
        try await repository.set(Keys.asaClientSecret, value: creds.clientSecret)
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
