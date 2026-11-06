@testable import App
import Foundation
import Testing
import Vapor

@Suite("Apple Ads insights: overview")
struct AppleAdsInsightsServiceTests {
    static let app = AppleAdsFixtures.ownApp

    struct Harness {
        let service: AppleAdsInsightsService
        let repo: InMemoryAppleAdsDataRepository
    }

    static func harness(running: Bool = false) -> Harness {
        let repo = InMemoryAppleAdsDataRepository()
        let service = AppleAdsInsightsService(
            repository: repo,
            watchedApps: InMemoryWatchedAppRepository([app]),
            syncRunning: { running },
            today: { "2026-11-06" }
        )
        return Harness(service: service, repo: repo)
    }

    /// Stores a successful sync of `snapshot` for account 42, like the sync does.
    static func synced(_ repo: InMemoryAppleAdsDataRepository, _ snapshot: AppleAdsSnapshot) async throws {
        try await repo.replace(adAccountId: 42, from: "2026-08-09", to: "2026-11-06", with: snapshot)
        await repo.seedRun(AppleAdsSyncRun(
            id: UUID(), adAccountId: 42, trigger: .manual, outcome: .succeeded,
            startedAt: Date(), finishedAt: Date(), fromDate: "2026-08-09", toDate: "2026-11-06", error: nil
        ))
    }

    static func day(_ campaign: Int64, _ date: String, taps: Int, installs: Int, spend: Double) -> AppleAdsCampaignDay {
        AppleAdsCampaignDay(campaignId: campaign, date: date, metrics: AppleAdsFixtures.metrics(taps: taps, installs: installs, spend: spend), currency: "USD")
    }

    @Test("overview sums the current and previous periods per campaign")
    func overviewSumsCurrentAndPreviousPeriods() async throws {
        let h = Self.harness()
        var snapshot = AppleAdsSnapshot()
        snapshot.campaigns = [AppleAdsFixtures.campaign]
        snapshot.campaignDays = [
            Self.day(1, "2026-11-05", taps: 100, installs: 4, spend: 20),   // current (latest data day)
            Self.day(1, "2026-10-30", taps: 60, installs: 2, spend: 10),    // current
            Self.day(1, "2026-10-28", taps: 50, installs: 1, spend: 8),     // previous
            Self.day(1, "2026-10-01", taps: 999, installs: 99, spend: 999), // outside both
        ]
        try await Self.synced(h.repo, snapshot)

        let o = try await h.service.overview(watchedAppId: Self.app.id!, days: 7)
        #expect(o.to == "2026-11-05")
        #expect(o.from == "2026-10-30")
        #expect(o.previousTo == "2026-10-29")
        #expect(o.previousFrom == "2026-10-23")
        #expect(o.currency == "USD")
        #expect(o.totals.taps == 160)
        #expect(o.totals.spend == 30)
        #expect(o.totals.cpi == 5)
        #expect(o.previousTotals.taps == 50)
        #expect(o.campaigns.map(\.id) == ["1"])
        #expect(o.campaigns.first?.previous.spend == 8)
        #expect(o.daily.count == 7)
        #expect(o.daily.first?.date == "2026-10-30")
        #expect(o.daily.last?.tapInstalls == 4)
        #expect(o.daily.map(\.spend).reduce(0, +) == 30)
        #expect(o.lastSync.lastSuccessAt != nil)
    }

    @Test("campaigns promoting other apps are counted, not summed")
    func otherAppsCampaignsExcluded() async throws {
        let h = Self.harness()
        let other = AppleAdsCampaignInfo(id: 2, appStoreId: 555, name: "Other app", status: "RUNNING", countries: ["US"], dailyBudget: 5, currency: "USD")
        var snapshot = AppleAdsSnapshot()
        snapshot.campaigns = [AppleAdsFixtures.campaign, other]
        snapshot.campaignDays = [
            Self.day(1, "2026-11-05", taps: 10, installs: 1, spend: 2),
            Self.day(2, "2026-11-05", taps: 500, installs: 50, spend: 100),
        ]
        try await Self.synced(h.repo, snapshot)

        let o = try await h.service.overview(watchedAppId: Self.app.id!, days: 30)
        #expect(o.totals.taps == 10)
        #expect(o.campaigns.map(\.id) == ["1"])
        #expect(o.otherAppsCampaignCount == 1)
    }

    @Test("before any successful sync the overview is empty but carries sync status")
    func overviewWithoutSyncIsEmptyWithStatus() async throws {
        let h = Self.harness(running: true)
        let o = try await h.service.overview(watchedAppId: Self.app.id!, days: 7)
        #expect(o.campaigns.isEmpty)
        #expect(o.totals == AppleAdsMath.dto(.zero))
        #expect(o.lastSync.running)
        #expect(o.lastSync.lastSuccessAt == nil)
        #expect(o.to == "2026-11-06")
    }

    @Test("days other than 7 or 30 are a 400")
    func daysMustBe7Or30() async throws {
        let h = Self.harness()
        await #expect {
            _ = try await h.service.overview(watchedAppId: Self.app.id!, days: 14)
        } throws: { error in
            (error as? any AbortError)?.status == .badRequest
        }
    }
}
