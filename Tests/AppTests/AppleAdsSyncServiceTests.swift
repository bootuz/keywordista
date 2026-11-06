@testable import App
import Foundation
import Logging
import Testing

@Suite("Apple Ads sync service")
struct AppleAdsSyncServiceTests {
    private static let today = "2026-11-06"

    private struct Harness {
        let service: AppleAdsSyncService
        let client: ScriptedReportingClient
        let repo: InMemoryAppleAdsDataRepository
        let settings: ASASettingsStub
    }

    private static func harness(
        settings: ASASettingsStub = ASASettingsStub(),
        apps: [WatchedApp] = [AppleAdsFixtures.ownApp],
        keywords: [Keyword] = []
    ) -> Harness {
        let client = ScriptedReportingClient()
        let repo = InMemoryAppleAdsDataRepository()
        let service = AppleAdsSyncService(
            settings: settings,
            repository: repo,
            watchedApps: InMemoryWatchedAppRepository(apps),
            keywords: InMemoryKeywordRepository(keywords),
            makeClient: { _ in client },
            today: { today },
            logger: Logger(label: "t")
        )
        return Harness(service: service, client: client, repo: repo, settings: settings)
    }

    private static func seedSuccess(_ repo: InMemoryAppleAdsDataRepository, account: Int64 = 42, to: String) async {
        await repo.seedRun(AppleAdsSyncRun(
            id: UUID(), adAccountId: account, trigger: .scheduled, outcome: .succeeded,
            startedAt: Date(), finishedAt: Date(), fromDate: "2026-08-01", toDate: to, error: nil
        ))
    }

    private static func basicData(_ client: ScriptedReportingClient, taps: Int = 10) async {
        await client.configure { c in
            c.campaigns = [AppleAdsFixtures.campaign]
            c.keywordsByCampaign = [1: [AppleAdsKeywordInfo(id: 5, campaignId: 1, adGroupId: 2, text: "flashcards", matchType: "EXACT", status: "ACTIVE", bid: 1, currency: "USD")]]
            c.campaignDayRows = [AppleAdsCampaignDay(campaignId: 1, date: "2026-11-05", metrics: AppleAdsFixtures.metrics(taps: taps, installs: 1, spend: 3), currency: "USD")]
            c.searchTermDayRows = [AppleAdsSearchTermDay(campaignId: 1, adGroupId: 2, keywordId: nil, term: "anki cards", source: "AUTO", country: "US", date: "2026-11-05", metrics: AppleAdsFixtures.metrics(taps: 4, installs: 1, spend: 1))]
        }
    }

    @Test("a first sync backfills 90 days")
    func firstSyncBackfills90Days() async throws {
        let h = Self.harness()
        await Self.basicData(h.client)
        let run = try await h.service.sync(trigger: .manual)
        #expect(run.outcome == .succeeded)
        #expect(run.fromDate == "2026-08-09")
        #expect(run.toDate == Self.today)
        #expect(await h.client.requestedWindows.first?.from == "2026-08-09")
    }

    @Test("after a recent success only the last 7 days are pulled")
    func recentSyncPullsLast7Days() async throws {
        let h = Self.harness()
        await Self.seedSuccess(h.repo, to: "2026-11-05")
        await Self.basicData(h.client)
        let run = try await h.service.sync(trigger: .scheduled)
        #expect(run.fromDate == "2026-10-31")
        #expect(await h.client.requestedWindows.first?.from == "2026-10-31")
    }

    @Test("a last success more than 7 days old triggers a 90-day backfill")
    func staleSyncBackfills90Days() async throws {
        let h = Self.harness()
        await Self.seedSuccess(h.repo, to: "2026-10-29")
        await Self.basicData(h.client)
        let run = try await h.service.sync(trigger: .scheduled)
        #expect(run.fromDate == "2026-08-09")
    }

    @Test("a revised day replaces the stored numbers instead of adding to them")
    func resyncReplacesRevisedDays() async throws {
        let h = Self.harness()
        await Self.basicData(h.client, taps: 10)
        _ = try await h.service.sync(trigger: .manual)
        await Self.basicData(h.client, taps: 12)
        _ = try await h.service.sync(trigger: .manual)
        let days = try await h.repo.campaignDays(adAccountId: 42, from: "2026-11-05", to: "2026-11-05")
        #expect(days.map(\.metrics.taps) == [12])
    }

    @Test("a failed report keeps previous data and records readable copy")
    func failedSyncKeepsPreviousData() async throws {
        let h = Self.harness()
        await Self.basicData(h.client)
        _ = try await h.service.sync(trigger: .manual)
        await h.client.configure { c in
            c.campaignDayRows = [AppleAdsCampaignDay(campaignId: 1, date: "2026-11-05", metrics: AppleAdsFixtures.metrics(taps: 99), currency: "USD")]
            c.searchTermError = AppleAdsError.http(status: 500, message: "")
        }
        await #expect(throws: AppleAdsError.http(status: 500, message: "")) { _ = try await h.service.sync(trigger: .manual) }
        let days = try await h.repo.campaignDays(adAccountId: 42, from: "2026-11-05", to: "2026-11-05")
        #expect(days.map(\.metrics.taps) == [10])
        let last = try #require(try await h.repo.latestRun())
        #expect(last.outcome == .failed)
        #expect(last.error == AppleAdsError.http(status: 500, message: "").description)
    }

    @Test("popularity failing doesn't fail the sync")
    func popularityFailureDoesNotFailSync() async throws {
        let h = Self.harness()
        await Self.basicData(h.client)
        await h.client.configure { $0.popularityError = AppleAdsError.http(status: 400, message: "bad genre") }
        let run = try await h.service.sync(trigger: .manual)
        #expect(run.outcome == .succeeded)
        #expect(await h.client.popularityRequests.count == 1)
    }

    @Test("popularity covers bid keywords, tracked terms and converted search terms in the app's genre")
    func popularityTermsAndGenre() async throws {
        let h = Self.harness(keywords: [Keyword(id: UUID(), term: "Study Deck", countryCode: "us")])
        await Self.basicData(h.client)
        _ = try await h.service.sync(trigger: .manual)
        let request = try #require(await h.client.popularityRequests.first)
        #expect(Set(request.terms) == ["flashcards", "study deck", "anki cards"])
        #expect(request.country == "US")
        #expect(request.genre == "EDUCATION")
    }

    @Test("syncing a different ad account deletes the previous account's rows")
    func accountSwitchPurgesOtherAccount() async throws {
        let h = Self.harness()
        await Self.basicData(h.client)
        _ = try await h.service.sync(trigger: .manual)
        await h.client.configure { $0.adAccountId = 77 }
        _ = try await h.service.sync(trigger: .manual)
        #expect(try await h.repo.campaigns(adAccountId: 42).isEmpty)
        #expect(try await h.repo.campaigns(adAccountId: 77).count == 1)
    }

    @Test("without credentials nothing is recorded")
    func noCredentialsRecordsNoRun() async throws {
        let h = Self.harness(settings: ASASettingsStub(nil))
        await #expect(throws: AppleAdsError.notConnected) { _ = try await h.service.sync(trigger: .scheduled) }
        #expect(try await h.repo.latestRun() == nil)
    }

    @Test("a failed suggestions call keeps the previous suggestions")
    func failedIdeasKeepPreviousIdeas() async throws {
        let h = Self.harness()
        await Self.basicData(h.client)
        await h.client.configure { $0.ideaRows = [AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "memory game", popularity: 2)] }
        _ = try await h.service.sync(trigger: .manual)
        await h.client.configure { $0.ideasError = AppleAdsError.http(status: 500, message: "") }
        let run = try await h.service.sync(trigger: .manual)
        #expect(run.outcome == .succeeded)
        #expect(try await h.repo.ideas(adAccountId: 42, appStoreId: 99).map(\.text) == ["memory game"])
    }
}

