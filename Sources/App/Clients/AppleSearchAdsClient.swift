import Foundation
import Vapor

// Live client for Apple Search Ads (Campaign Management API v5).
//
// Auth model — different from the ASC client:
//
//   1. The user pastes their own *long-lived* JWT (up to 180 days) into the
//      ASA settings form. We store it in `clientSecret`. The JWT is generated
//      offline by the user using their EC private key — keywordista never
//      sees the private key. Apple's current OAuth surface treats this JWT
//      as the `client_secret` value (not a JWT-bearer `client_assertion`).
//   2. On each API call we hold an in-memory `ASATokenCache` that exchanges
//      that JWT for a short-lived (1-hour) OAuth access token via
//      https://appleid.apple.com/auth/oauth2/token. Per Apple's docs the
//      exchange uses URL query parameters with an empty body. Subsequent
//      calls reuse the cached token until ~3 min before it expires.
//   3. Downstream ASA calls use `Authorization: Bearer <access_token>` plus
//      `X-AP-Context: orgId=<orgId>` when `orgId` is configured. The OAuth
//      call itself does *not* take `X-AP-Context` — it's only for the data
//      endpoints.
//
// The cache is a process-singleton (wired via `Application.storage`) so that
// a busy request cycle doesn't burn 100 OAuth round-trips.

protocol AppleSearchAdsClientProtocol: Sendable {
    /// Lists all ASA campaigns the JWT issuer can see. Used to discover
    /// the campaign id(s) for a given storefront without making the user
    /// hard-code anything.
    func listCampaigns() async throws -> [ASACampaign]

    /// Pulls search-term performance for a campaign over a date window.
    /// Empty array is a valid response (a new campaign has no data yet).
    func searchTermsReport(
        campaignId: Int64,
        startDate: Date,
        endDate: Date
    ) async throws -> [ASASearchTerm]
}

/// Tiny async-only HTTP seam that the ASA client and TokenCache use.
/// Production wraps Vapor's `Client`; tests inject a trivial stub without
/// dragging in `EventLoopFuture` machinery just to record fixture calls.
protocol ASAHTTPClient: Sendable {
    func get(url: String, headers: HTTPHeaders) async throws -> ClientResponse
    func post(url: String, headers: HTTPHeaders, body: Data) async throws -> ClientResponse
}

struct VaporASAHTTPClient: ASAHTTPClient {
    let client: any Client

    func get(url: String, headers: HTTPHeaders) async throws -> ClientResponse {
        try await client.get(URI(string: url), headers: headers)
    }

    func post(url: String, headers: HTTPHeaders, body: Data) async throws -> ClientResponse {
        try await client.post(URI(string: url), headers: headers) { req in
            req.body = .init(data: body)
        }
    }
}

struct ASACampaign: Sendable, Equatable {
    let id: Int64
    let name: String
    let countriesOrRegions: [String]  // ISO uppercased, e.g. ["US"]
    let displayStatus: String         // e.g. "RUNNING", "PAUSED"
}

struct ASASearchTerm: Sendable, Equatable {
    let text: String           // The query the user typed
    let source: String         // "AUTO" (Search Match) | "TARGETED" | …
    let impressions: Int
    let taps: Int
    let ttr: Double            // 0…1
    let localSpend: Double     // in the campaign's currency
}

// MARK: - Client

struct AppleSearchAdsClient: AppleSearchAdsClientProtocol {
    let credentials: ASACredentials
    let tokenCache: ASATokenCache
    let http: any ASAHTTPClient
    let logger: Logger

    static let oauthURL = "https://appleid.apple.com/auth/oauth2/token"
    static let baseURL = "https://api.searchads.apple.com"
    // Match ITunesSearchClient for consistency — ASA can be slow.
    static let requestTimeoutSeconds: UInt64 = 30

    enum Failure: Error, CustomStringConvertible {
        case oauthFailed(status: HTTPResponseStatus, body: String)
        case invalidCredentials
        case noOrgAccess
        case http(status: HTTPResponseStatus, body: String)

        var description: String {
            switch self {
            case .oauthFailed(let status, let body):
                return "ASA OAuth failed (\(status.code)). Check Client ID and the JWT — it may have expired. Body: \(body.prefix(300))"
            case .invalidCredentials:
                return "Apple Search Ads rejected the access token (401). The JWT may have expired or the Org ID is wrong."
            case .noOrgAccess:
                return "Apple Search Ads returned 403. The JWT issuer doesn't have access to this org's data."
            case .http(let status, let body):
                return "ASA HTTP \(status.code): \(body.prefix(300))"
            }
        }
    }

    // MARK: Public

    func listCampaigns() async throws -> [ASACampaign] {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: Int64
                let name: String?
                let countriesOrRegions: [String]?
                let displayStatus: String?
            }
            let data: [Item]
        }
        let env: Envelope = try await authedGet(
            "/api/v5/campaigns?limit=1000",
            as: Envelope.self
        )
        return env.data.map {
            ASACampaign(
                id: $0.id,
                name: $0.name ?? "",
                countriesOrRegions: ($0.countriesOrRegions ?? []).map { $0.uppercased() },
                displayStatus: $0.displayStatus ?? "UNKNOWN"
            )
        }
    }

    func searchTermsReport(
        campaignId: Int64,
        startDate: Date,
        endDate: Date
    ) async throws -> [ASASearchTerm] {
        struct Body: Encodable {
            struct OrderBy: Encodable { let field: String; let sortOrder: String }
            struct Pagination: Encodable { let offset: Int; let limit: Int }
            struct Selector: Encodable {
                let orderBy: [OrderBy]
                let conditions: [String]   // empty
                let pagination: Pagination
            }
            let startTime: String
            let endTime: String
            let timeZone = "ORTZ"  // ASA requires this for search-term reports
            // Apple's input validator requires AT LEAST ONE of
            // `returnRowTotals: true` or a `granularity` value, otherwise
            // /searchterms returns 400 INVALID_INPUT "needs to ask for
            // rowTotals or granularity". We don't actually consume row
            // totals (the Envelope ignores the field), but flipping this
            // satisfies the validator without changing the per-row shape.
            let returnRowTotals = true
            let returnGrandTotals = false
            let returnRecordsWithNoMetrics = false
            let selector: Selector
        }
        struct Envelope: Decodable {
            struct Money: Decodable { let amount: String? }
            struct Total: Decodable {
                let impressions: Int?
                let taps: Int?
                let ttr: Double?
                let localSpend: Money?
            }
            struct Metadata: Decodable {
                let searchTermText: String?
                let searchTermSource: String?
            }
            struct Row: Decodable {
                let other: Bool?
                let total: Total?
                let metadata: Metadata?
            }
            // Apple's v5 reports response wraps the rows under
            // `data.reportingDataResponse.row` — NOT `data.row` directly.
            // The previous decoder had an extra-level mismatch which was
            // masked by other failures (missing orgId → 403, missing
            // returnRowTotals → 400). With those resolved, the decoder
            // now sees the real envelope shape.
            struct Reporting: Decodable { let row: [Row] }
            struct DataBlock: Decodable { let reportingDataResponse: Reporting }
            let data: DataBlock
        }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        let body = Body(
            startTime: df.string(from: startDate),
            endTime: df.string(from: endDate),
            selector: .init(
                orderBy: [.init(field: "impressions", sortOrder: "DESCENDING")],
                conditions: [],
                pagination: .init(offset: 0, limit: 1000)
            )
        )

        let env: Envelope = try await authedPost(
            "/api/v5/reports/campaigns/\(campaignId)/searchterms",
            body: body,
            as: Envelope.self
        )

        return env.data.reportingDataResponse.row.compactMap { row in
            // Skip the "other" rollup row that Apple sometimes returns.
            if row.other == true { return nil }
            guard
                let meta = row.metadata,
                let text = meta.searchTermText,
                !text.isEmpty
            else { return nil }
            let total = row.total
            let spend = Double(total?.localSpend?.amount ?? "0") ?? 0
            return ASASearchTerm(
                text: text,
                source: meta.searchTermSource ?? "UNKNOWN",
                impressions: total?.impressions ?? 0,
                taps: total?.taps ?? 0,
                ttr: total?.ttr ?? 0,
                localSpend: spend
            )
        }
    }

    // MARK: HTTP plumbing

    private func authedGet<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try await withAuth { token in
            try await rawGet(path, token: token)
        }
    }

    private func authedPost<B: Encodable, T: Decodable>(
        _ path: String,
        body: B,
        as: T.Type
    ) async throws -> T {
        try await withAuth { token in
            try await rawPost(path, body: body, token: token)
        }
    }

    /// Runs `fetch`, and if it raises `Failure.invalidCredentials` re-exchanges
    /// the token and tries one more time. This handles the case where the cached
    /// access token was revoked or rotated server-side before its `expires_in`.
    private func withAuth<T>(_ fetch: (String) async throws -> ClientResponse) async throws -> T where T: Decodable {
        var token = try await tokenCache.token(
            credentials: credentials,
            http: http,
            logger: logger
        )
        var response = try await fetch(token)
        if response.status == .unauthorized {
            await tokenCache.invalidate(clientId: credentials.clientId)
            token = try await tokenCache.token(
                credentials: credentials,
                http: http,
                logger: logger
            )
            response = try await fetch(token)
        }
        return try Self.decode(response: response, logger: logger)
    }

    private func rawGet(_ path: String, token: String) async throws -> ClientResponse {
        let url = Self.baseURL + path
        let headers = authHeaders(token: token)
        let httpRef = http
        return try await withTimeout {
            try await httpRef.get(url: url, headers: headers)
        }
    }

    private func rawPost<B: Encodable>(_ path: String, body: B, token: String) async throws -> ClientResponse {
        let url = Self.baseURL + path
        let headers: HTTPHeaders = {
            var h = authHeaders(token: token)
            h.add(name: "Content-Type", value: "application/json")
            return h
        }()
        let payload = try JSONEncoder().encode(body)
        let httpRef = http
        return try await withTimeout {
            try await httpRef.post(url: url, headers: headers, body: payload)
        }
    }

    private func authHeaders(token: String) -> HTTPHeaders {
        var h = HTTPHeaders()
        h.add(name: "Authorization", value: "Bearer \(token)")
        h.add(name: "Accept", value: "application/json")
        if let orgId = credentials.orgId, !orgId.isEmpty {
            h.add(name: "X-AP-Context", value: "orgId=\(orgId)")
        }
        return h
    }

    private func withTimeout(_ work: @escaping @Sendable () async throws -> ClientResponse) async throws -> ClientResponse {
        try await withThrowingTaskGroup(of: ClientResponse.self) { group in
            let timeout = Self.requestTimeoutSeconds
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                throw Abort(.gatewayTimeout, reason: "ASA request timed out after \(timeout)s")
            }
            guard let first = try await group.next() else {
                throw Abort(.internalServerError, reason: "ASA request produced no result")
            }
            group.cancelAll()
            return first
        }
    }

    static func decode<T: Decodable>(response: ClientResponse, logger: Logger) throws -> T {
        if response.status == .unauthorized { throw Failure.invalidCredentials }
        if response.status == .forbidden { throw Failure.noOrgAccess }
        guard response.status == .ok else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            logger.error("ASA returned \(response.status): \(body.prefix(300))")
            throw Failure.http(status: response.status, body: body)
        }
        guard let buffer = response.body else {
            throw Failure.http(status: response.status, body: "(empty body)")
        }
        return try JSONDecoder().decode(T.self, from: Data(buffer: buffer))
    }
}

// MARK: - OAuth token cache

/// Process-wide cache: keep one entry per Client ID so multiple requests
/// share the same access token. Wired as an `Application.storage` value
/// in `Container.swift` so it survives across request lifetimes.
actor ASATokenCache {
    private struct Entry {
        let token: String
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]

    // Apple says access tokens are good for ~1 hour; renew 3 min early.
    private static let renewalSkew: TimeInterval = 180

    func invalidate(clientId: String) { entries[clientId] = nil }

    /// Returns a valid access token, exchanging the JWT if the cache is cold
    /// or the cached token is within the renewal skew.
    func token(
        credentials: ASACredentials,
        http: any ASAHTTPClient,
        logger: Logger
    ) async throws -> String {
        if let entry = entries[credentials.clientId],
           entry.expiresAt.timeIntervalSinceNow > Self.renewalSkew {
            return entry.token
        }
        let exchanged = try await Self.exchange(credentials: credentials, http: http, logger: logger)
        entries[credentials.clientId] = Entry(
            token: exchanged.token,
            expiresAt: Date().addingTimeInterval(exchanged.expiresIn)
        )
        return exchanged.token
    }

    private struct Exchanged { let token: String; let expiresIn: TimeInterval }
    private struct OAuthResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let token_type: String
    }

    private static func exchange(
        credentials: ASACredentials,
        http: any ASAHTTPClient,
        logger: Logger
    ) async throws -> Exchanged {
        // Apple's documented shape: all params on the URL query, empty body.
        // The user's stored `clientSecret` (a JWT they generated offline) is
        // passed verbatim as `client_secret`.
        let query = [
            "grant_type=client_credentials",
            "client_id=\(percent(credentials.clientId))",
            "client_secret=\(percent(credentials.clientSecret))",
            "scope=searchadsorg",
        ].joined(separator: "&")
        let url = AppleSearchAdsClient.oauthURL + "?" + query

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        headers.add(name: "Accept", value: "application/json")

        let response = try await http.post(
            url: url,
            headers: headers,
            body: Data()
        )

        guard response.status == .ok, let buffer = response.body else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            logger.error("ASA OAuth returned \(response.status): \(body.prefix(300))")
            throw AppleSearchAdsClient.Failure.oauthFailed(status: response.status, body: body)
        }
        let decoded = try JSONDecoder().decode(OAuthResponse.self, from: Data(buffer: buffer))
        return Exchanged(token: decoded.access_token, expiresIn: TimeInterval(decoded.expires_in))
    }

    private static func percent(_ s: String) -> String {
        // RFC 3986 unreserved + a tight extra set; conservatively encode everything else.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
