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

protocol AppleAdsInsightsServiceProtocol: Sendable {
    func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO
}

/// Reads the synced Apple Ads mirror for the Apple Ads screens. Never calls
/// Apple: everything here comes from the last sync.
struct AppleAdsInsightsService: AppleAdsInsightsServiceProtocol {
    let repository: any AppleAdsDataRepositoryProtocol
    let watchedApps: any WatchedAppRepositoryProtocol
    let syncRunning: @Sendable () async -> Bool
    let today: @Sendable () -> String

    static let allowedDays: Set<Int> = [7, 30]

    func syncStatus() async throws -> AppleAdsSyncStatus {
        AppleAdsSyncStatus(
            running: await syncRunning(),
            lastRun: try await repository.latestRun(),
            lastSuccessAt: try await repository.lastSuccessfulRun(adAccountId: nil)?.finishedAt
        )
    }

    func overview(watchedAppId: UUID, days: Int) async throws -> AppleAdsOverviewDTO {
        guard Self.allowedDays.contains(days) else {
            throw Abort(.badRequest, reason: "days must be 7 or 30")
        }
        guard let app = try await watchedApps.find(id: watchedAppId) else {
            throw Abort(.notFound, reason: "App not found")
        }
        let status = try await syncStatus()
        // The account is whichever one last synced; the sync deletes the rest.
        let account = try await repository.lastSuccessfulRun(adAccountId: nil)?.adAccountId
        var end = today()
        if let account, let latest = try await repository.latestDate(adAccountId: account) { end = latest }
        let period = AppleAdsMath.periods(endingAt: end, days: days)

        guard let account else {
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
