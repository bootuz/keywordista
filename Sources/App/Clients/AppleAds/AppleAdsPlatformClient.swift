import AppleAdsClient
import Foundation
import Logging
import OpenAPIRuntime

// Apple Ads Platform API v1 adapter behind the protocol the suggestion,
// popularity, and opportunity services already consume. The services never
// see v1 types: if Apple changes the wire again, only this file moves.
//
// Auth: the user's long-lived JWT is the OAuth client secret. The library
// exchanges it for access tokens and refreshes them; `AppleAdsSession`
// owns the one client per credential set.
//
// Ad-account context: every v1 data call carries `X-AP-Context:
// adAccountId=…`. Which account comes from settings when the user picked
// one, otherwise from the ACL list (see `resolveAdAccountId`).

protocol AppleSearchAdsClientProtocol: Sendable {
    /// Lists all Apple Ads campaigns the API user can see. Used to discover
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

struct AppleAdsPlatformClient: AppleSearchAdsClientProtocol {
    let credentials: ASACredentials
    let session: AppleAdsSession
    let logger: Logger

    static let campaignPageSize = 1000
    static let reportPageSize = 5000
    /// Privacy-suppressed rows reach consumers under this literal text, as
    /// they did in v5, so the services' LOW_VOLUME handling keeps working.
    static let lowVolumeText = "LOW_VOLUME"

    init(credentials: ASACredentials, session: AppleAdsSession, logger: Logger) {
        self.credentials = credentials
        self.session = session
        self.logger = logger
    }

    // MARK: Ad accounts

    func listAdAccounts() async throws -> [ASAAdAccount] {
        let response = try await call { api in
            switch try await api.getUserAcls() {
            case .ok(let ok): return try ok.body.json
            case .badRequest(let r): throw AppleAdsError.status(400, try? r.body.json)
            case .unauthorized: throw AppleAdsError.unauthorized
            case .forbidden: throw AppleAdsError.forbidden
            case .notFound(let r): throw AppleAdsError.status(404, try? r.body.json)
            case .tooManyRequests: throw AppleAdsError.rateLimited
            case .internalServerError(let r): throw AppleAdsError.status(500, try? r.body.json)
            case .undocumented(let status, _): throw AppleAdsError.status(status)
            }
        }
        return (response.result?.acls ?? []).compactMap { acl in
            guard let account = acl.adAccount, let id = account.id else { return nil }
            return ASAAdAccount(
                id: String(id),
                name: account.name ?? "",
                orgId: account.orgId.map(String.init) ?? "",
                roles: acl.roles ?? []
            )
        }
    }

    /// Explicit setting → the only account → the account in the v5 org the
    /// user configured before v1 → ask. Never guess between accounts: reading
    /// the wrong account's search terms would silently corrupt suggestions.
    func resolveAdAccountId() async throws -> Int64 {
        if let raw = credentials.adAccountId?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let id = Int64(raw) else { throw AppleAdsError.invalidAdAccountId(raw) }
            return id
        }
        if let cached = await session.resolvedAdAccount(for: credentials) { return cached }
        let accounts = try await listAdAccounts()
        let chosen: ASAAdAccount? = if accounts.count == 1 {
            accounts[0]
        } else if let orgId = credentials.orgId, !orgId.isEmpty,
                  case let matches = accounts.filter({ $0.orgId == orgId }), matches.count == 1 {
            matches[0]
        } else {
            nil
        }
        guard let chosen, let id = Int64(chosen.id) else {
            throw AppleAdsError.adAccountSelectionRequired(accounts)
        }
        await session.rememberAdAccount(id, for: credentials)
        return id
    }

    // MARK: Campaigns

    func listCampaigns() async throws -> [ASACampaign] {
        try await campaignFieldsAll().map { f in
            ASACampaign(
                id: f.id,
                name: f.name ?? "",
                countriesOrRegions: (f.targeting?.countryOrRegion?.include ?? []).map { $0.uppercased() },
                displayStatus: f.displayStatus ?? "UNKNOWN"
            )
        }
    }

    /// v1's campaign query returns untyped objects. Decode only the fields
    /// we use, tolerating an `id` sent as a string: Apple's docs show both.
    struct CampaignFields: Decodable {
        struct Targeting: Decodable {
            struct Countries: Decodable { let include: [String]? }
            let countryOrRegion: Countries?
        }
        let id: Int64
        let name: String?
        let displayStatus: String?
        let targeting: Targeting?
        let promotedObjectId: String?
        let dailyBudget: Budget?

        struct Budget: Decodable {
            struct Money: Decodable { let amount: String?; let currency: String? }
            let value: Money?
        }

        enum CodingKeys: String, CodingKey { case id, name, displayStatus, targeting, promotedObjectId, dailyBudget }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? c.decode(Int64.self, forKey: .id) {
                id = number
            } else {
                let text = try c.decode(String.self, forKey: .id)
                guard let number = Int64(text) else {
                    throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "campaign id \"\(text)\" isn't a number")
                }
                id = number
            }
            name = try c.decodeIfPresent(String.self, forKey: .name)
            displayStatus = try c.decodeIfPresent(String.self, forKey: .displayStatus)
            targeting = try c.decodeIfPresent(Targeting.self, forKey: .targeting)
            // Apple documents a string, but tolerate a number like the campaign id.
            if let text = try? c.decodeIfPresent(String.self, forKey: .promotedObjectId) {
                promotedObjectId = text
            } else {
                promotedObjectId = (try? c.decodeIfPresent(Int64.self, forKey: .promotedObjectId)).flatMap { $0.map(String.init) }
            }
            dailyBudget = try? c.decodeIfPresent(Budget.self, forKey: .dailyBudget)
        }
    }

    // MARK: Search terms

    func searchTermsReport(campaignId: Int64, startDate: Date, endDate: Date) async throws -> [ASASearchTerm] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let campaignFilter = try OpenAPIValueContainer(unvalidatedValue: Int(campaignId))
        var terms: [ASASearchTerm] = []
        var offset = 0
        while true {
            let request = Components.Schemas.AppsReportingRequest(
                pagination: .init(offset: offset, pageSize: Self.reportPageSize),
                filters: [.init(field: "campaignId", _operator: .equals, value: campaignFilter)],
                timeRange: .init(
                    start: Self.day(startDate),
                    end: Self.day(endDate),
                    timeZone: .ortz,
                    granularity: .daily
                )
            )
            let page = try await call { api in
                switch try await api.appsSearchTermReports(headers: .init(xApContext: context), body: .json(request)) {
                case .ok(let ok): return try ok.body.json
                case .badRequest(let r): throw AppleAdsError.status(400, try? r.body.json)
                case .unauthorized: throw AppleAdsError.unauthorized
                case .forbidden: throw AppleAdsError.forbidden
                case .notFound(let r): throw AppleAdsError.status(404, try? r.body.json)
                case .tooManyRequests: throw AppleAdsError.rateLimited
                case .internalServerError(let r): throw AppleAdsError.status(500, try? r.body.json)
                case .undocumented(let status, _): throw AppleAdsError.status(status)
                }
            }
            let rows = page.result?.rows ?? []
            terms += rows.map(Self.searchTerm(from:))
            offset += rows.count
            let total = page.pagination?.totalCount ?? offset
            if rows.count < Self.reportPageSize || offset >= total { return terms }
        }
    }

    private static func searchTerm(from row: Components.Schemas.AppsSearchTermReportRow) -> ASASearchTerm {
        let metrics = row.totalMetrics
        let text = row.metadata?.searchTermText.flatMap { $0.isEmpty ? nil : $0 }
        return ASASearchTerm(
            text: text ?? lowVolumeText,
            source: row.metadata?.searchTermSource ?? "AUTO",
            impressions: Int(metrics?.impressions ?? 0),
            taps: Int(metrics?.taps ?? 0),
            ttr: metrics?.ttr ?? 0,
            localSpend: metrics?.localSpend.flatMap { Double($0.amount) } ?? 0
        )
    }

    /// `yyyy-MM-dd` in UTC: the dates callers pass are UTC day boundaries.
    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    // MARK: Plumbing

    /// Runs one API call on the session's client and turns every failure,
    /// including client construction and the OAuth exchange, into `AppleAdsError`.
    func call<T: Sendable>(_ body: (AppleAdsAPI) async throws -> T) async throws -> T {
        do {
            return try await body(try await session.client(for: credentials))
        } catch {
            let mapped = AppleAdsError.from(error)
            logger.warning("Apple Ads call failed: \(mapped)")
            throw mapped
        }
    }
}
