import Foundation
import Vapor

struct AppleAdsCampaignSummaryDTO: Content, Equatable {
    /// Apple's IDs exceed JavaScript's safe integers, so they travel as strings.
    let id: String
    let name: String
    let status: String
    let metrics: AppleAdsMetricsDTO
    let previous: AppleAdsMetricsDTO
}

struct AppleAdsDailyPointDTO: Content, Equatable {
    let date: String
    let spend: Double
    let tapInstalls: Int
}

struct AppleAdsOverviewDTO: Content, Equatable {
    let currency: String?
    let from: String
    let to: String
    let previousFrom: String
    let previousTo: String
    let totals: AppleAdsMetricsDTO
    let previousTotals: AppleAdsMetricsDTO
    let campaigns: [AppleAdsCampaignSummaryDTO]
    let daily: [AppleAdsDailyPointDTO]
    /// Campaigns in the account that promote apps other than this one.
    let otherAppsCampaignCount: Int
    let lastSync: AppleAdsSyncStatus
}

struct AppleAdsKeywordRowDTO: Content, Equatable {
    let keywordId: String
    let text: String
    let matchType: String
    let status: String
    let campaignName: String
    let country: String
    let bid: Double?
    let suggestedBid: Double?
    /// Currency of the bid and spend amounts.
    let currency: String?
    let metrics: AppleAdsMetricsDTO
    /// Latest organic rank of the tracked keyword with this term in this country.
    let organicRank: Int?
    let trackedKeywordId: UUID?
    /// Organic rank 1–5: the paid tap may be one the app would have had anyway.
    let alreadyRanksWell: Bool
}

struct AppleAdsIdeaDTO: Content, Equatable {
    let term: String
    let country: String
    /// Paid results for the term in the period; nil for Apple's suggestions.
    let metrics: AppleAdsMetricsDTO?
    /// Apple's search popularity, 1–100, from the latest synced week.
    let popularity: Int?
    let organicRank: Int?
    let difficulty: Int?
    let trackedKeywordId: UUID?
}

struct AppleAdsBidIdeasDTO: Content, Equatable {
    /// Currency of the spend amounts.
    let currency: String?
    /// Search terms that brought installs but aren't exact-match bids yet.
    let converted: [AppleAdsIdeaDTO]
    /// Apple's keyword recommendations for the app, minus ones already bid.
    let suggestions: [AppleAdsIdeaDTO]
    /// Search terms with enough taps to judge and no installs.
    let wasted: [AppleAdsIdeaDTO]
}

protocol AppleAdsInsightsServiceProtocol: Sendable {
    func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO
    func keywords(watchedAppId: UUID, days: Int) async throws -> [AppleAdsKeywordRowDTO]
    func bidIdeas(watchedAppId: UUID, days: Int) async throws -> AppleAdsBidIdeasDTO
}

/// Reads the synced Apple Ads mirror for the Apple Ads screens. Never calls
/// Apple: everything here comes from the last sync.
struct AppleAdsInsightsService: AppleAdsInsightsServiceProtocol {
    let repository: any AppleAdsDataRepositoryProtocol
    let watchedApps: any WatchedAppRepositoryProtocol
    let keywords: any KeywordRepositoryProtocol
    let rankChecks: any RankCheckRepositoryProtocol
    let syncRunning: @Sendable () async -> Bool
    let today: @Sendable () -> String

    static let allowedDays: Set<Int> = [7, 30]
    static let ranksWellThrough = 5
    /// Below this many taps, zero installs is noise rather than waste.
    static let wastedMinTaps = 50

    func syncStatus() async throws -> AppleAdsSyncStatus {
        AppleAdsSyncStatus(
            running: await syncRunning(),
            lastRun: try await repository.latestRun(),
            lastSuccessAt: try await repository.lastSuccessfulRun(adAccountId: nil)?.finishedAt
        )
    }

    /// The app, the synced account (nil before a first success) and the period.
    private struct Scope {
        let app: WatchedApp
        let account: Int64?
        let period: (current: ClosedRange<String>, previous: ClosedRange<String>)
    }

    private func scope(watchedAppId: UUID, days: Int) async throws -> Scope {
        guard Self.allowedDays.contains(days) else {
            throw Abort(.badRequest, reason: "days must be 7 or 30")
        }
        guard let app = try await watchedApps.find(id: watchedAppId) else {
            throw Abort(.notFound, reason: "App not found")
        }
        // The account is whichever one last synced; the sync deletes the rest.
        let lastGood = try await repository.lastSuccessfulRun(adAccountId: nil)
        let account = lastGood?.adAccountId
        // Periods end at the newest complete synced day. The sync's last day
        // was "today" when it ran, so its numbers are partial and would make
        // every comparison with the previous period look down.
        var end = today()
        if let account, let latest = try await repository.latestDate(adAccountId: account) {
            end = latest
            if let syncedTo = lastGood?.toDate { end = min(end, AppleAdsMath.shift(syncedTo, days: -1)) }
        }
        return Scope(app: app, account: account, period: AppleAdsMath.periods(endingAt: end, days: days))
    }

    func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO {
        let scope = try await scope(watchedAppId: watchedAppId, days: days)
        let (app, period) = (scope.app, scope.period)
        let status = try await syncStatus()
        guard let account = scope.account else {
            return Self.emptyOverview(period: period, status: status)
        }

        let allCampaigns = try await repository.campaigns(adAccountId: account)
        let campaigns = allCampaigns.filter { $0.appStoreId == app.appStoreId }
        let ids = Set(campaigns.map(\.id))
        let rows = try await repository.campaignDays(
            adAccountId: account, from: period.previous.lowerBound, to: period.current.upperBound
        ).filter { ids.contains($0.campaignId) }

        var current: [Int64: AppleAdsMetrics] = [:]
        var previous: [Int64: AppleAdsMetrics] = [:]
        var byDay: [String: AppleAdsMetrics] = [:]
        for row in rows {
            if period.current.contains(row.date) {
                current[row.campaignId, default: .zero] = current[row.campaignId, default: .zero] + row.metrics
                byDay[row.date, default: .zero] = byDay[row.date, default: .zero] + row.metrics
            } else if period.previous.contains(row.date) {
                previous[row.campaignId, default: .zero] = previous[row.campaignId, default: .zero] + row.metrics
            }
        }

        // Spelled out with explicit types: as one chained map/sort over
        // tuples, Swift 6.2's type checker gives up on it ("unable to
        // type-check this expression in reasonable time").
        var summaries: [AppleAdsCampaignSummaryDTO] = []
        for c in campaigns {
            let metrics: AppleAdsMetrics = current[c.id] ?? .zero
            let before: AppleAdsMetrics = previous[c.id] ?? .zero
            summaries.append(AppleAdsCampaignSummaryDTO(
                id: String(c.id), name: c.name, status: c.status,
                metrics: AppleAdsMath.dto(metrics), previous: AppleAdsMath.dto(before)
            ))
        }
        summaries.sort { (a: AppleAdsCampaignSummaryDTO, b: AppleAdsCampaignSummaryDTO) -> Bool in
            if a.metrics.spend != b.metrics.spend { return a.metrics.spend > b.metrics.spend }
            return a.name < b.name
        }

        return AppleAdsOverviewDTO(
            currency: campaigns.lazy.compactMap(\.currency).first ?? rows.lazy.compactMap(\.currency).first,
            from: period.current.lowerBound, to: period.current.upperBound,
            previousFrom: period.previous.lowerBound, previousTo: period.previous.upperBound,
            totals: AppleAdsMath.dto(current.values.reduce(.zero, +)),
            previousTotals: AppleAdsMath.dto(previous.values.reduce(.zero, +)),
            campaigns: summaries,
            daily: AppleAdsMath.days(in: period.current).map { day in
                let m = byDay[day] ?? .zero
                return AppleAdsDailyPointDTO(date: day, spend: m.spend, tapInstalls: m.tapInstalls)
            },
            otherAppsCampaignCount: allCampaigns.count - campaigns.count,
            lastSync: status
        )
    }

    func keywords(watchedAppId: UUID, days: Int) async throws -> [AppleAdsKeywordRowDTO] {
        let scope = try await scope(watchedAppId: watchedAppId, days: days)
        guard let account = scope.account else { return [] }
        let period = scope.period.current

        let campaigns = try await repository.campaigns(adAccountId: account)
            .filter { $0.appStoreId == scope.app.appStoreId }
        let campaignNames = Dictionary(campaigns.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let infos = Dictionary(
            try await repository.keywords(adAccountId: account)
                .filter { campaignNames[$0.campaignId] != nil }
                .map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        struct Key: Hashable { let keywordId: Int64; let country: String }
        var sums: [Key: AppleAdsMetrics] = [:]
        var suggested: [Key: (date: String, bid: Double)] = [:]
        for day in try await repository.keywordDays(adAccountId: account, from: period.lowerBound, to: period.upperBound)
        where infos[day.keywordId] != nil {
            let key = Key(keywordId: day.keywordId, country: day.country.uppercased())
            sums[key, default: .zero] = sums[key, default: .zero] + day.metrics
            if let bid = day.suggestedBid, day.date >= (suggested[key]?.date ?? "") {
                suggested[key] = (day.date, bid)
            }
        }

        // Tracked keywords by (lowercased term, uppercased country).
        var tracked: [String: Keyword] = [:]
        for keyword in try await keywords.all() {
            tracked[Self.matchKey(keyword.term, keyword.countryCode)] = keyword
        }

        var rows: [AppleAdsKeywordRowDTO] = []
        for (key, metrics) in sums {
            guard let info = infos[key.keywordId] else { continue }
            let match = tracked[Self.matchKey(info.text, key.country)]
            var rank: Int?
            if let match, let id = match.id, let appId = scope.app.id {
                rank = try await rankChecks.latest(keywordID: id, watchedAppID: appId)?.rank
            }
            rows.append(AppleAdsKeywordRowDTO(
                keywordId: String(info.id), text: info.text, matchType: info.matchType, status: info.status,
                campaignName: campaignNames[info.campaignId] ?? "", country: key.country,
                bid: info.bid, suggestedBid: suggested[key]?.bid, currency: info.currency,
                metrics: AppleAdsMath.dto(metrics),
                organicRank: rank, trackedKeywordId: match?.id,
                alreadyRanksWell: rank.map { (1...Self.ranksWellThrough).contains($0) } ?? false
            ))
        }
        return rows.sorted {
            $0.metrics.spend != $1.metrics.spend ? $0.metrics.spend > $1.metrics.spend
                : ($0.text, $0.country) < ($1.text, $1.country)
        }
    }

    func bidIdeas(watchedAppId: UUID, days: Int) async throws -> AppleAdsBidIdeasDTO {
        let scope = try await scope(watchedAppId: watchedAppId, days: days)
        guard let account = scope.account else { return AppleAdsBidIdeasDTO(currency: nil, converted: [], suggestions: [], wasted: []) }
        let period = scope.period.current

        let campaigns = try await repository.campaigns(adAccountId: account)
            .filter { $0.appStoreId == scope.app.appStoreId }
        let campaignIds = Set(campaigns.map(\.id))
        let countriesByCampaign = Dictionary(campaigns.map { ($0.id, $0.countries.map { $0.uppercased() }) }, uniquingKeysWith: { a, _ in a })
        // What's already bid, keyed by term|COUNTRY: a keyword bids in every
        // storefront its campaign serves.
        var bid: Set<String> = []
        var exactBid: Set<String> = []
        for keyword in try await repository.keywords(adAccountId: account) where campaignIds.contains(keyword.campaignId) {
            for country in countriesByCampaign[keyword.campaignId] ?? [] {
                let key = Self.matchKey(keyword.text, country)
                bid.insert(key)
                if keyword.matchType.uppercased() == "EXACT" { exactBid.insert(key) }
            }
        }

        // Search terms summed per term and storefront.
        var sums: [String: (term: String, country: String, metrics: AppleAdsMetrics)] = [:]
        for row in try await repository.searchTermDays(adAccountId: account, from: period.lowerBound, to: period.upperBound)
        where campaignIds.contains(row.campaignId) && !AppleAdsMirrorReader.isLowVolume(row.term) {
            let key = Self.matchKey(row.term, row.country)
            let current = sums[key]
            sums[key] = (current?.term ?? row.term.lowercased(), row.country.uppercased(), (current?.metrics ?? .zero) + row.metrics)
        }

        let converted = sums.filter { $0.value.metrics.tapInstalls >= 1 && !exactBid.contains($0.key) }.values
            .sorted { ($0.metrics.tapInstalls, $1.term) > ($1.metrics.tapInstalls, $0.term) }
        let wasted = sums.values.filter { $0.metrics.taps >= Self.wastedMinTaps && $0.metrics.tapInstalls == 0 }
            .sorted { ($0.metrics.spend, $1.term) > ($1.metrics.spend, $0.term) }
        var seenIdeas: Set<String> = []
        let suggestions = try await repository.ideas(adAccountId: account, appStoreId: scope.app.appStoreId)
            .filter { idea in
                let key = Self.matchKey(idea.text, idea.country)
                return !bid.contains(key) && seenIdeas.insert(key).inserted
            }

        // Popularity and organic rank for every term shown.
        let shown = converted.map { ($0.term, $0.country) } + wasted.map { ($0.term, $0.country) }
            + suggestions.map { ($0.text.lowercased(), $0.country.uppercased()) }
        var popularity: [String: Int] = [:]
        for p in try await repository.popularity(terms: Set(shown.map(\.0)), countries: Set(shown.map(\.1))) {
            if let value = p.popularity100 { popularity[Self.matchKey(p.term, p.country)] = value }
        }
        var tracked: [String: Keyword] = [:]
        for keyword in try await keywords.all() {
            tracked[Self.matchKey(keyword.term, keyword.countryCode)] = keyword
        }

        func idea(_ term: String, _ country: String, _ metrics: AppleAdsMetrics?) async throws -> AppleAdsIdeaDTO {
            let key = Self.matchKey(term, country)
            let match = tracked[key]
            var check: RankCheck?
            if let id = match?.id, let appId = scope.app.id {
                check = try await rankChecks.latest(keywordID: id, watchedAppID: appId)
            }
            return AppleAdsIdeaDTO(
                term: term, country: country.uppercased(), metrics: metrics.map(AppleAdsMath.dto),
                popularity: popularity[key], organicRank: check?.rank, difficulty: check?.difficulty,
                trackedKeywordId: match?.id
            )
        }

        var convertedOut: [AppleAdsIdeaDTO] = []
        for c in converted { convertedOut.append(try await idea(c.term, c.country, c.metrics)) }
        var wastedOut: [AppleAdsIdeaDTO] = []
        for w in wasted { wastedOut.append(try await idea(w.term, w.country, w.metrics)) }
        var suggestionsOut: [AppleAdsIdeaDTO] = []
        for s in suggestions { suggestionsOut.append(try await idea(s.text.lowercased(), s.country, nil)) }
        return AppleAdsBidIdeasDTO(
            currency: campaigns.lazy.compactMap(\.currency).first,
            converted: convertedOut, suggestions: suggestionsOut, wasted: wastedOut
        )
    }

    private static func matchKey(_ term: String, _ country: String) -> String {
        term.trimmingCharacters(in: .whitespaces).lowercased() + "|" + country.uppercased()
    }

    private static func emptyOverview(
        period: (current: ClosedRange<String>, previous: ClosedRange<String>),
        status: AppleAdsSyncStatus
    ) -> AppleAdsOverviewDTO {
        AppleAdsOverviewDTO(
            currency: nil,
            from: period.current.lowerBound, to: period.current.upperBound,
            previousFrom: period.previous.lowerBound, previousTo: period.previous.upperBound,
            totals: AppleAdsMath.dto(.zero), previousTotals: AppleAdsMath.dto(.zero),
            campaigns: [], daily: [], otherAppsCampaignCount: 0, lastSync: status
        )
    }
}
