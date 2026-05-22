import Crypto
import Foundation
import Vapor

// Live client for Apple's App Store Connect API. The only thing we need from
// ASC right now is the per-locale `keywords` field on the latest version of
// each watched app — surfaced in the dashboard as the amber "ASC" badge so
// the user can tell which tracked terms are actually targeted in the store.
//
// Auth: ES256-signed JWT generated per request from the developer's .p8 EC
// private key. Tokens are short-lived (20 min) and never persisted; we sign
// a fresh one for each `fetchKeywords` call to keep the client stateless.

protocol AppStoreConnectClientProtocol: Sendable {
    /// Returns locale → list of normalized keyword terms for the *latest*
    /// version of the app with `bundleId`. `[:]` when the app exists but has
    /// no localizations; throws when the bundle ID isn't owned by the JWT's
    /// issuer or the request otherwise fails.
    func fetchKeywords(forBundleId bundleId: String) async throws -> [String: [String]]
}

struct AppStoreConnectClient: AppStoreConnectClientProtocol {
    let credentials: ASCCredentials
    let client: any Client
    let logger: Logger

    static let baseURL = "https://api.appstoreconnect.apple.com"
    // Apple recommends 20-minute tokens and rejects anything > 20 min.
    static let tokenLifetimeSeconds: TimeInterval = 1_200
    static let requestTimeoutSeconds: UInt64 = 30

    enum Failure: Error, CustomStringConvertible {
        case invalidPrivateKey(String)
        case invalidCredentials
        case appNotFound(bundleId: String)
        case noVersions(bundleId: String)
        case http(status: HTTPResponseStatus, body: String)

        var description: String {
            switch self {
            case .invalidPrivateKey(let why):
                return "ASC private key is not a usable P-256 PEM: \(why)"
            case .invalidCredentials:
                return "App Store Connect rejected the credentials (401). Check Key ID, Issuer ID, and the .p8 contents."
            case .appNotFound(let bundleId):
                return "No app with bundle ID \(bundleId) is visible to these credentials."
            case .noVersions(let bundleId):
                return "App \(bundleId) has no App Store versions yet."
            case .http(let status, let body):
                return "ASC HTTP \(status.code): \(body.prefix(300))"
            }
        }
    }

    func fetchKeywords(forBundleId bundleId: String) async throws -> [String: [String]] {
        let jwt = try Self.signJWT(credentials: credentials, now: Date())
        guard let appId = try await fetchAppId(bundleId: bundleId, jwt: jwt) else {
            throw Failure.appNotFound(bundleId: bundleId)
        }
        guard let versionId = try await fetchLatestVersionId(appId: appId, jwt: jwt) else {
            throw Failure.noVersions(bundleId: bundleId)
        }
        let raw = try await fetchVersionLocalizations(versionId: versionId, jwt: jwt)

        var out: [String: [String]] = [:]
        for loc in raw {
            let terms = Self.parseKeywords(loc.keywords)
            if !terms.isEmpty { out[loc.locale] = terms }
        }
        return out
    }

    // ── HTTP ─────────────────────────────────────────────────────────────────

    private func get<T: Decodable>(_ path: String, query: String?, jwt: String, as: T.Type) async throws -> T {
        var url = URI(string: Self.baseURL + path)
        if let query { url.query = query }
        let token = jwt
        let response = try await withThrowingTaskGroup(of: ClientResponse.self) { group in
            let theClient = client
            let theURL = url
            let timeout = Self.requestTimeoutSeconds
            group.addTask {
                try await theClient.get(theURL, headers: [
                    "Authorization": "Bearer \(token)",
                    "Accept": "application/json",
                ])
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                throw Abort(.gatewayTimeout, reason: "ASC request timed out after \(timeout)s")
            }
            guard let first = try await group.next() else {
                throw Abort(.internalServerError, reason: "ASC request produced no result")
            }
            group.cancelAll()
            return first
        }

        if response.status == .unauthorized {
            throw Failure.invalidCredentials
        }
        guard response.status == .ok else {
            let bodyText: String
            if let buf = response.body { bodyText = String(buffer: buf) } else { bodyText = "" }
            logger.error("ASC \(path) returned \(response.status): \(bodyText.prefix(300))")
            throw Failure.http(status: response.status, body: bodyText)
        }
        guard let buffer = response.body else {
            throw Failure.http(status: response.status, body: "(empty body)")
        }
        return try JSONDecoder().decode(T.self, from: Data(buffer: buffer))
    }

    private struct DataListResponse<A: Decodable>: Decodable {
        struct Resource: Decodable {
            let id: String
            let attributes: A?
        }
        let data: [Resource]
    }

    private struct Empty: Decodable {}
    private struct VersionAttributes: Decodable {
        let createdDate: String?
    }
    private struct VersionLocalizationAttributes: Decodable {
        let locale: String
        let keywords: String?
    }

    private func fetchAppId(bundleId: String, jwt: String) async throws -> String? {
        let encoded = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleId
        let response: DataListResponse<Empty> = try await get(
            "/v1/apps",
            query: "filter[bundleId]=\(encoded)&limit=1",
            jwt: jwt,
            as: DataListResponse<Empty>.self
        )
        return response.data.first?.id
    }

    private func fetchLatestVersionId(appId: String, jwt: String) async throws -> String? {
        // The nested `/v1/apps/{id}/appStoreVersions` endpoint rejects `sort`
        // (only the top-level `/v1/appStoreVersions` accepts it — confirmed
        // against live ASC). Fetch up to 20 versions and pick the newest by
        // createdDate client-side; that's effectively no extra cost for a
        // single app and avoids depending on the server's default ordering.
        let response: DataListResponse<VersionAttributes> = try await get(
            "/v1/apps/\(appId)/appStoreVersions",
            query: "limit=20&fields[appStoreVersions]=createdDate",
            jwt: jwt,
            as: DataListResponse<VersionAttributes>.self
        )
        return response.data
            .compactMap { res -> (id: String, createdDate: String)? in
                guard let date = res.attributes?.createdDate else { return nil }
                return (res.id, date)
            }
            // ISO-8601 strings sort lexicographically the same as chronologically.
            .max(by: { $0.createdDate < $1.createdDate })?
            .id
    }

    struct VersionLocalization: Sendable {
        let locale: String
        let keywords: String?
    }

    private func fetchVersionLocalizations(versionId: String, jwt: String) async throws -> [VersionLocalization] {
        let response: DataListResponse<VersionLocalizationAttributes> = try await get(
            "/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations",
            query: "limit=200&fields[appStoreVersionLocalizations]=locale,keywords",
            jwt: jwt,
            as: DataListResponse<VersionLocalizationAttributes>.self
        )
        return response.data.compactMap { res in
            guard let attrs = res.attributes else { return nil }
            return VersionLocalization(locale: attrs.locale, keywords: attrs.keywords)
        }
    }

    // ── JWT ──────────────────────────────────────────────────────────────────

    /// Signs an ES256 JWT for App Store Connect. Exposed as `static` so tests
    /// can verify the encoded structure without a network client.
    static func signJWT(credentials: ASCCredentials, now: Date) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        } catch {
            throw Failure.invalidPrivateKey(String(describing: error))
        }

        // Use plain `Encodable` structs so we never produce a JSON whose key
        // ordering differs from what we expect in tests. JSONEncoder on Linux
        // and Darwin both honour the source-order of stored properties.
        struct Header: Encodable {
            let alg = "ES256"
            let kid: String
            let typ = "JWT"
        }
        struct Payload: Encodable {
            let iss: String
            let iat: Int
            let exp: Int
            let aud = "appstoreconnect-v1"
        }

        let header = Header(kid: credentials.keyId)
        let iat = Int(now.timeIntervalSince1970)
        let payload = Payload(
            iss: credentials.issuerId,
            iat: iat,
            exp: iat + Int(tokenLifetimeSeconds)
        )

        let encoder = JSONEncoder()
        // No pretty printing — every byte goes into the signature input.
        let headerB64 = base64URL(try encoder.encode(header))
        let payloadB64 = base64URL(try encoder.encode(payload))
        let signingInput = "\(headerB64).\(payloadB64)"

        let signature = try key.signature(for: Data(signingInput.utf8))
        // ES256 demands raw 64-byte r||s, not DER. `.rawRepresentation` is that.
        let sigB64 = base64URL(signature.rawRepresentation)
        return "\(signingInput).\(sigB64)"
    }

    /// RFC 4648 §5 base64url with no padding — JWT's required encoding.
    static func base64URL(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        // Trailing '=' padding must be stripped for JWT.
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    // ── Parsing ──────────────────────────────────────────────────────────────

    /// ASC's `keywords` field is a single comma-separated string. We split,
    /// trim, lowercase, and drop empties. Exposed for tests.
    static func parseKeywords(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
