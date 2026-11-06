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
    let metrics: AppleAdsMetricsDTO
    /// Latest organic rank of the tracked keyword with this term in this country.
    let organicRank: Int?
    let trackedKeywordId: UUID?
    /// Organic rank 1–5: the paid tap may be one the app would have had anyway.
    let alreadyRanksWell: Bool
}

protocol AppleAdsInsightsServiceProtocol: Sendable {
    func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO
    func keywords(watchedAppId: UUID, days: Int) async throws -> [AppleAdsKeywordRowDTO]
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
        let account = try await repository.lastSuccessfulRun(adAccountId: nil)?.adAccountId
        // Periods end at the newest synced day, not today: Apple's numbers
        // for today are partial and would make every comparison look down.
        var end = today()
        if let account, let latest = try await repository.latestDate(adAccountId: account) { end = latest }
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

        let summaries = campaigns
            .map { c in
                (spend: current[c.id]?.spend ?? 0, dto: AppleAdsCampaignSummaryDTO(
                    id: String(c.id), name: c.name, status: c.status,
                    metrics: AppleAdsMath.dto(current[c.id] ?? .zero),
                    previous: AppleAdsMath.dto(previous[c.id] ?? .zero)
                ))
            }
            .sorted { $0.spend != $1.spend ? $0.spend > $1.spend : $0.dto.name < $1.dto.name }
            .map(\.dto)

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
                bid: info.bid, suggestedBid: suggested[key]?.bid,
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
