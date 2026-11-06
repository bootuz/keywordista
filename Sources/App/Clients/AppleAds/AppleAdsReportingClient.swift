import AppleAdsClient
import Foundation
import OpenAPIRuntime

/// The reads the Apple Ads sync needs. `AppleAdsPlatformClient` is the live
/// implementation; the sync service depends on this protocol only, so its
/// tests script Apple's answers without HTTP.
protocol AppleAdsReportingClientProtocol: Sendable {
    func resolveAdAccountId() async throws -> Int64
    func campaignInfos() async throws -> [AppleAdsCampaignInfo]
    func keywords(campaignId: Int64) async throws -> [AppleAdsKeywordInfo]
    func campaignDays(campaignIds: [Int64], from: String, to: String) async throws -> [AppleAdsCampaignDay]
    func keywordDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay]
    func searchTermDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay]
    func termPopularity(terms: [String], country: String, genre: String) async throws -> [AppleAdsTermPopularity]
    func keywordIdeas(appStoreId: Int64, country: String) async throws -> [AppleAdsKeywordIdea]
}

extension AppleAdsPlatformClient: AppleAdsReportingClientProtocol {
    static let popularityBatchSize = 100
    /// How many weeks of popularity to ask for; the newest one Apple has
    /// published wins (new weeks post with about a week's lag).
    static let popularityWeeks = 4

    // MARK: Campaigns and keywords

    /// Every app campaign, decoded tolerantly (v1 returns untyped objects).
    func campaignFieldsAll() async throws -> [CampaignFields] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        var all: [CampaignFields] = []
        var offset = 0
        while true {
            let request = Components.Schemas.QueryRequest(
                filters: [.init(field: "promotedObjectType", _operator: .equals, value: "APPSTORE_APP")],
                pagination: .init(pageSize: Int32(Self.campaignPageSize), offset: Int32(offset), fetchTotalCount: true)
            )
            let page = try await call { api in
                switch try await api.postCampaignsQuery(headers: .init(xApContext: context), body: .json(request)) {
                case .ok(let ok): return try ok.body.json.value1
                case .badRequest(let r): throw AppleAdsError.status(400, try? r.body.json)
                case .unauthorized: throw AppleAdsError.unauthorized
                case .forbidden: throw AppleAdsError.forbidden
                case .notFound(let r): throw AppleAdsError.status(404, try? r.body.json)
                case .tooManyRequests: throw AppleAdsError.rateLimited
                case .internalServerError(let r): throw AppleAdsError.status(500, try? r.body.json)
                case .undocumented(let status, _): throw AppleAdsError.status(status)
                }
            }
            let items = page.result ?? []
            all += try items.map { try Self.decodeObject(CampaignFields.self, from: $0, what: "campaign") }
            offset += items.count
            let total = page.pagination?.totalCount.map(Int.init) ?? offset
            if items.isEmpty || offset >= total { return all }
        }
    }

    func campaignInfos() async throws -> [AppleAdsCampaignInfo] {
        try await campaignFieldsAll().map { f in
            AppleAdsCampaignInfo(
                id: f.id,
                appStoreId: f.promotedObjectId.flatMap { Int64($0) } ?? 0,
                name: f.name ?? "",
                status: f.displayStatus ?? "UNKNOWN",
                countries: (f.targeting?.countryOrRegion?.include ?? []).map { $0.uppercased() },
                dailyBudget: f.dailyBudget?.value?.amount.flatMap(Double.init),
                currency: f.dailyBudget?.value?.currency
            )
        }
    }

    private struct KeywordFields: Decodable {
        struct Money: Decodable { let amount: String?; let currency: String? }
        let id: Int64
        let campaignId: Int64?
        let adGroupId: Int64?
        let text: String?
        let matchType: String?
        let status: String?
        let bid: Money?
    }

    func keywords(campaignId: Int64) async throws -> [AppleAdsKeywordInfo] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let campaignFilter = try OpenAPIValueContainer(unvalidatedValue: Int(campaignId))
        var all: [AppleAdsKeywordInfo] = []
        var offset = 0
        while true {
            let request = Components.Schemas.QueryRequest(
                filters: [.init(field: "campaignId", _operator: .equals, value: campaignFilter)],
                pagination: .init(pageSize: Int32(Self.campaignPageSize), offset: Int32(offset), fetchTotalCount: true)
            )
            let page = try await call { api in
                switch try await api.postKeywordsQuery(headers: .init(xApContext: context), body: .json(request)) {
                case .ok(let ok): return try ok.body.json.value1
                case .badRequest(let r): throw AppleAdsError.status(400, try? r.body.json)
                case .unauthorized: throw AppleAdsError.unauthorized
                case .forbidden: throw AppleAdsError.forbidden
                case .notFound(let r): throw AppleAdsError.status(404, try? r.body.json)
                case .tooManyRequests: throw AppleAdsError.rateLimited
                case .internalServerError(let r): throw AppleAdsError.status(500, try? r.body.json)
                case .undocumented(let status, _): throw AppleAdsError.status(status)
                }
            }
            let items = page.result ?? []
            for item in items {
                let k = try Self.decodeObject(KeywordFields.self, from: item, what: "keyword")
                all.append(AppleAdsKeywordInfo(
                    id: k.id, campaignId: k.campaignId ?? campaignId, adGroupId: k.adGroupId ?? 0,
                    text: k.text ?? "", matchType: k.matchType ?? "UNKNOWN", status: k.status ?? "UNKNOWN",
                    bid: k.bid?.amount.flatMap(Double.init), currency: k.bid?.currency
                ))
            }
            offset += items.count
            let total = page.pagination?.totalCount.map(Int.init) ?? offset
            if items.isEmpty || offset >= total { return all }
        }
    }

    // MARK: Daily reports

    func campaignDays(campaignIds: [Int64], from: String, to: String) async throws -> [AppleAdsCampaignDay] {
        guard !campaignIds.isEmpty else { return [] }
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        // Why no filter: the campaign report answers 400 "Filters contain
        // unsupported fields campaignId", so it returns every app campaign
        // and the wanted ones are picked out below.
        let wanted = Set(campaignIds)
        var days: [AppleAdsCampaignDay] = []
        var offset = 0
        while true {
            let request = Self.reportRequest(
                filters: [],
                from: from, to: to, groupByCountry: false, offset: offset
            )
            let page = try await call { api in
                switch try await api.appsCampaignReports(headers: .init(xApContext: context), body: .json(request)) {
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
            for row in rows {
                guard let id = row.metadata?.id, wanted.contains(id) else { continue }
                for g in row.granularMetrics ?? [] {
                    guard let date = g.value1.date else { continue }
                    days.append(AppleAdsCampaignDay(
                        campaignId: id, date: date, metrics: Self.metrics(g.value1), currency: g.value1.localSpend?.currency
                    ))
                }
            }
            offset += rows.count
            if Self.isLastPage(rows: rows.count, offset: offset, total: page.pagination?.totalCount) { return days }
        }
    }

    func keywordDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsKeywordDay] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let campaignFilter = try OpenAPIValueContainer(unvalidatedValue: Int(campaignId))
        var days: [AppleAdsKeywordDay] = []
        var offset = 0
        while true {
            let request = Self.reportRequest(
                filters: [.init(field: "campaignId", _operator: .equals, value: campaignFilter)],
                from: from, to: to, groupByCountry: true, offset: offset
            )
            let page = try await call { api in
                switch try await api.appsKeywordReports(headers: .init(xApContext: context), body: .json(request)) {
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
            for row in rows {
                guard let meta = row.metadata, let id = meta.id else { continue }
                let country = (meta.countryOrRegion ?? "").uppercased()
                for g in row.granularMetrics ?? [] {
                    guard let date = g.date else { continue }
                    days.append(AppleAdsKeywordDay(
                        keywordId: id, campaignId: meta.campaignId ?? campaignId, country: country, date: date,
                        metrics: Self.metrics(g), suggestedBid: row.insights?.bidRecommendation?.suggestedBidAmount
                    ))
                }
            }
            offset += rows.count
            if Self.isLastPage(rows: rows.count, offset: offset, total: page.pagination?.totalCount) { return days }
        }
    }

    func searchTermDays(campaignId: Int64, from: String, to: String) async throws -> [AppleAdsSearchTermDay] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let campaignFilter = try OpenAPIValueContainer(unvalidatedValue: Int(campaignId))
        var days: [AppleAdsSearchTermDay] = []
        var offset = 0
        while true {
            let request = Self.reportRequest(
                filters: [.init(field: "campaignId", _operator: .equals, value: campaignFilter)],
                from: from, to: to, groupByCountry: true, offset: offset
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
            for row in rows {
                let meta = row.metadata
                let text = meta?.searchTermText.flatMap { $0.isEmpty ? nil : $0 }
                for g in row.granularMetrics ?? [] {
                    guard let date = g.date else { continue }
                    days.append(AppleAdsSearchTermDay(
                        campaignId: meta?.campaignId ?? campaignId,
                        adGroupId: meta?.adGroupId ?? 0,
                        keywordId: meta?.keyword?.id,
                        term: text ?? Self.lowVolumeText,
                        source: meta?.searchTermSource ?? "AUTO",
                        country: (meta?.countryOrRegion ?? "").uppercased(),
                        date: date,
                        metrics: Self.metrics(g)
                    ))
                }
            }
            offset += rows.count
            if Self.isLastPage(rows: rows.count, offset: offset, total: page.pagination?.totalCount) { return days }
        }
    }

    // MARK: Popularity and ideas

    func termPopularity(terms: [String], country: String, genre: String) async throws -> [AppleAdsTermPopularity] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let (start, end) = Self.popularityWeeks(endingBefore: Date())
        let countryCode = country.uppercased()
        var out: [AppleAdsTermPopularity] = []
        let unique = Array(Set(terms.map { $0.lowercased() })).sorted()
        for batchStart in stride(from: 0, to: unique.count, by: Self.popularityBatchSize) {
            let batch = Array(unique[batchStart..<min(batchStart + Self.popularityBatchSize, unique.count)])
            let request = Components.Schemas.SearchTermPopularityQueryRequest(
                filters: [
                    .init(field: "searchTerm", _operator: ._in, value: try OpenAPIValueContainer(unvalidatedValue: batch)),
                    .init(field: "countryOrRegion", _operator: .equals, value: try OpenAPIValueContainer(unvalidatedValue: countryCode)),
                    .init(field: "genre", _operator: .equals, value: try OpenAPIValueContainer(unvalidatedValue: genre)),
                ],
                timeRange: .init(start: start, end: end, timeZone: .utc, granularity: .weeklySunSat),
                pagination: .init(offset: 0, pageSize: Self.reportPageSize)
            )
            let page = try await call { api in
                switch try await api.searchTermPopularityQuery(headers: .init(xApContext: context), body: .json(request)) {
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
            for row in page.result?.rows ?? [] {
                guard let term = row.searchTerm, let week = row.week else { continue }
                out.append(AppleAdsTermPopularity(
                    term: term.lowercased(),
                    country: (row.countryOrRegion ?? countryCode).uppercased(),
                    genre: row.genre ?? genre,
                    week: week,
                    popularity100: row.searchPopularity1to100,
                    popularity5: row.searchPopularity1to5,
                    rankInGenre: row.rankInGenre
                ))
            }
        }
        return out
    }

    func keywordIdeas(appStoreId: Int64, country: String) async throws -> [AppleAdsKeywordIdea] {
        let context = XApContext(adAccountID: try await resolveAdAccountId()).rawValue
        let countryCode = country.uppercased()
        let request = Components.Schemas.RecommendationQueryRequest(
            filters: [
                .init(field: "promotedObjectId", _operator: .equals, value: [String(appStoreId)]),
                .init(field: "promotedObjectType", _operator: .equals, value: ["APPSTORE_APP"]),
                .init(field: "countriesOrRegions", _operator: ._in, value: [countryCode]),
            ]
        )
        let response = try await call { api in
            switch try await api.queryKeywordSuggestions(headers: .init(xApContext: context), body: .json(request)) {
            case .ok(let ok): return try ok.body.json
            case .badRequest: throw AppleAdsError.status(400)
            case .unauthorized: throw AppleAdsError.unauthorized
            case .forbidden: throw AppleAdsError.forbidden
            case .notFound: throw AppleAdsError.status(404)
            case .tooManyRequests: throw AppleAdsError.rateLimited
            case .internalServerError: throw AppleAdsError.status(500)
            case .undocumented(let status, _): throw AppleAdsError.status(status)
            }
        }
        return (response.value2.result ?? []).compactMap { s in
            guard let text = s.text, !text.isEmpty else { return nil }
            return AppleAdsKeywordIdea(appStoreId: appStoreId, country: countryCode, text: text, popularity: s.popularity.map(Int.init))
        }
    }

    // MARK: Helpers

    private static func reportRequest(
        filters: [Components.Schemas.Filter],
        from: String, to: String, groupByCountry: Bool, offset: Int
    ) -> Components.Schemas.AppsReportingRequest {
        Components.Schemas.AppsReportingRequest(
            pagination: .init(offset: offset, pageSize: reportPageSize),
            filters: filters,
            groupBy: groupByCountry ? [.countryOrRegion] : nil,
            // ORTZ everywhere: search-term reports only support it, and one
            // timezone keeps the three reports' days aligned.
            timeRange: .init(start: from, end: to, timeZone: .ortz, granularity: .daily)
        )
    }

    private static func isLastPage(rows: Int, offset: Int, total: Int?) -> Bool {
        rows < reportPageSize || offset >= (total ?? offset)
    }

    private static func metrics(_ m: Components.Schemas.AppsMetrics) -> AppleAdsMetrics {
        AppleAdsMetrics(
            impressions: Int(m.impressions ?? 0),
            taps: Int(m.taps ?? 0),
            tapInstalls: Int(m.tapInstalls ?? 0),
            viewInstalls: Int(m.viewInstalls ?? 0),
            totalInstalls: Int(m.totalInstalls ?? 0),
            spend: m.localSpend.flatMap { Double($0.amount) } ?? 0
        )
    }

    static func decodeObject<T: Decodable>(_ type: T.Type, from object: OpenAPIObjectContainer, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(object))
        } catch {
            throw AppleAdsError.unreadableResponse("\(what): \(error)".prefix(200).description)
        }
    }

    /// Sunday … Saturday range covering the last `popularityWeeks` complete
    /// weeks before `date`, in UTC. Apple rejects ranges that don't sit on
    /// week boundaries.
    static func popularityWeeks(endingBefore date: Date) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday … 7 = Saturday
        let lastSaturday = calendar.date(byAdding: .day, value: -weekday, to: today)!
        let firstSunday = calendar.date(byAdding: .day, value: -(7 * popularityWeeks - 1), to: lastSaturday)!
        return (day(firstSunday), day(lastSaturday))
    }

}
