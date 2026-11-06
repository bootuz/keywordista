@testable import App
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@Suite("Apple Ads mirror repository")
struct AppleAdsDataRepositoryTests {

    private static func withRepo(_ body: (FluentAppleAdsDataRepository) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateAppleAdsMirror())
        try await app.autoMigrate()
        do {
            try await body(FluentAppleAdsDataRepository(db: app.db))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private static func m(taps: Int, installs: Int = 0, spend: Double = 0) -> AppleAdsMetrics {
        AppleAdsMetrics(impressions: taps * 10, taps: taps, tapInstalls: installs, viewInstalls: 0, totalInstalls: installs, spend: spend)
    }

    private static func day(_ d: Int) -> String { String(format: "2026-10-%02d", d) }

    private static func campaignDays(_ range: ClosedRange<Int>, taps: Int) -> [AppleAdsCampaignDay] {
        range.map { AppleAdsCampaignDay(campaignId: 1, date: day($0), metrics: m(taps: taps), currency: "USD") }
    }

    private static func snapshot(
        campaignDays: [AppleAdsCampaignDay] = [],
        keywordDays: [AppleAdsKeywordDay] = [],
        popularity: [AppleAdsTermPopularity] = []
    ) -> AppleAdsSnapshot {
        AppleAdsSnapshot(
            campaigns: [AppleAdsCampaignInfo(id: 1, appStoreId: 99, name: "C", status: "RUNNING", countries: ["US"], dailyBudget: 10, currency: "USD")],
            keywords: [AppleAdsKeywordInfo(id: 7, campaignId: 1, adGroupId: 2, text: "flashcards", matchType: "EXACT", status: "ACTIVE", bid: 1.2, currency: "USD")],
            campaignDays: campaignDays,
            keywordDays: keywordDays,
            searchTermDays: [],
            popularity: popularity,
            ideas: []
        )
    }

    @Test("replace swaps only the requested date window")
    func replaceSwapsOnlyTheWindow() async throws {
        try await Self.withRepo { repo in
            try await repo.replace(adAccountId: 42, from: Self.day(1), to: Self.day(10), with: Self.snapshot(campaignDays: Self.campaignDays(1...10, taps: 5)))
            try await repo.replace(adAccountId: 42, from: Self.day(6), to: Self.day(10), with: Self.snapshot(campaignDays: Self.campaignDays(6...10, taps: 9)))
            let days = try await repo.campaignDays(adAccountId: 42, from: Self.day(1), to: Self.day(10)).sorted { $0.date < $1.date }
            #expect(days.count == 10)
            #expect(days.prefix(5).allSatisfy { $0.metrics.taps == 5 })
            #expect(days.suffix(5).allSatisfy { $0.metrics.taps == 9 })
        }
    }

    @Test("a failing replace leaves every table as it was")
    func replaceIsAtomic() async throws {
        try await Self.withRepo { repo in
            // A stored day outside the next window: re-sending it collides with
            // the unique index, which makes the second write fail partway.
            let outside = AppleAdsKeywordDay(keywordId: 7, campaignId: 1, country: "US", date: Self.day(5), metrics: Self.m(taps: 1), suggestedBid: nil)
            try await repo.replace(adAccountId: 42, from: Self.day(1), to: Self.day(5), with: Self.snapshot(campaignDays: Self.campaignDays(1...3, taps: 5), keywordDays: [outside]))
            await #expect(throws: (any Error).self) {
                try await repo.replace(
                    adAccountId: 42, from: Self.day(1), to: Self.day(3),
                    with: Self.snapshot(campaignDays: Self.campaignDays(1...3, taps: 8), keywordDays: [outside])
                )
            }
            let days = try await repo.campaignDays(adAccountId: 42, from: Self.day(1), to: Self.day(3))
            #expect(days.count == 3)
            #expect(days.allSatisfy { $0.metrics.taps == 5 })
            #expect(try await repo.keywordDays(adAccountId: 42, from: Self.day(1), to: Self.day(3)).isEmpty)
        }
    }

    @Test("purge(except:) keeps only that ad account's rows")
    func purgeExceptKeepsOnlyThatAccount() async throws {
        try await Self.withRepo { repo in
            try await repo.replace(adAccountId: 1, from: Self.day(1), to: Self.day(2), with: Self.snapshot(campaignDays: Self.campaignDays(1...2, taps: 1)))
            try await repo.replace(adAccountId: 2, from: Self.day(1), to: Self.day(2), with: Self.snapshot(campaignDays: Self.campaignDays(1...2, taps: 2)))
            try await repo.purge(exceptAdAccountId: 2)
            #expect(try await repo.campaignDays(adAccountId: 1, from: Self.day(1), to: Self.day(2)).isEmpty)
            #expect(try await repo.campaigns(adAccountId: 1).isEmpty)
            #expect(try await repo.keywords(adAccountId: 1).isEmpty)
            #expect(try await repo.campaignDays(adAccountId: 2, from: Self.day(1), to: Self.day(2)).count == 2)
        }
    }

    @Test("purgeAll removes data and sync runs")
    func purgeAllRemovesRunsToo() async throws {
        try await Self.withRepo { repo in
            try await repo.replace(adAccountId: 1, from: Self.day(1), to: Self.day(2), with: Self.snapshot(campaignDays: Self.campaignDays(1...2, taps: 1)))
            let run = try await repo.startRun(trigger: .manual)
            try await repo.finishRun(id: run.id, adAccountId: 1, outcome: .succeeded, fromDate: Self.day(1), toDate: Self.day(2), error: nil)
            try await repo.purgeAll()
            #expect(try await repo.latestRun() == nil)
            #expect(try await repo.campaigns(adAccountId: 1).isEmpty)
            #expect(try await repo.latestDate(adAccountId: 1) == nil)
        }
    }

    @Test("popularity returns the latest week per term and country")
    func popularityReturnsLatestWeekPerTermAndCountry() async throws {
        try await Self.withRepo { repo in
            let rows = [
                AppleAdsTermPopularity(term: "flashcards", country: "US", genre: "EDUCATION", week: "2026-10-05", popularity100: 40, popularity5: 2, rankInGenre: 90),
                AppleAdsTermPopularity(term: "flashcards", country: "US", genre: "EDUCATION", week: "2026-10-12", popularity100: 55, popularity5: 3, rankInGenre: 70),
                AppleAdsTermPopularity(term: "flashcards", country: "DE", genre: "EDUCATION", week: "2026-10-12", popularity100: 20, popularity5: 1, rankInGenre: 300),
            ]
            try await repo.replace(adAccountId: 1, from: Self.day(1), to: Self.day(2), with: Self.snapshot(popularity: rows))
            let found = try await repo.popularity(terms: ["flashcards"], countries: ["US", "DE"]).sorted { $0.country > $1.country }
            #expect(found.map(\.popularity100) == [55, 20])
        }
    }

    @Test("lastSuccessfulRun ignores failed runs and other accounts")
    func lastSuccessfulRunIgnoresFailedAndOtherAccounts() async throws {
        try await Self.withRepo { repo in
            let ok = try await repo.startRun(trigger: .scheduled)
            try await repo.finishRun(id: ok.id, adAccountId: 1, outcome: .succeeded, fromDate: Self.day(1), toDate: Self.day(7), error: nil)
            let failed = try await repo.startRun(trigger: .manual)
            try await repo.finishRun(id: failed.id, adAccountId: 1, outcome: .failed, fromDate: nil, toDate: nil, error: "boom")
            let other = try await repo.startRun(trigger: .manual)
            try await repo.finishRun(id: other.id, adAccountId: 2, outcome: .succeeded, fromDate: Self.day(1), toDate: Self.day(9), error: nil)
            #expect(try await repo.lastSuccessfulRun(adAccountId: 1)?.id == ok.id)
            #expect(try await repo.latestRun()?.outcome == .succeeded)
        }
    }

    @Test("duplicate rows in one Apple response don't break the write")
    func replaceToleratesDuplicateRows() async throws {
        try await Self.withRepo { repo in
            var s = Self.snapshot(campaignDays: Self.campaignDays(1...1, taps: 5))
            let idea = AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "flashcards", popularity: 3)
            s.ideas = [idea, idea]
            s.campaignDays += Self.campaignDays(1...1, taps: 5)
            try await repo.replace(adAccountId: 42, from: Self.day(1), to: Self.day(1), with: s)
            #expect(try await repo.ideas(adAccountId: 42, appStoreId: 99).count == 1)
            #expect(try await repo.campaignDays(adAccountId: 42, from: Self.day(1), to: Self.day(1)).count == 1)
        }
    }

    @Test("ideas whose fetch failed keep their previous rows; the rest are replaced")
    func failedIdeaScopesKeepOldIdeas() async throws {
        try await Self.withRepo { repo in
            var first = Self.snapshot()
            first.ideas = [
                AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "old us", popularity: 3),
                AppleAdsKeywordIdea(appStoreId: 99, country: "DE", text: "old de", popularity: 3),
            ]
            try await repo.replace(adAccountId: 42, from: Self.day(1), to: Self.day(1), with: first)
            var second = Self.snapshot()
            second.ideas = [AppleAdsKeywordIdea(appStoreId: 99, country: "DE", text: "new de", popularity: 2)]
            second.failedIdeaScopes = [AppleAdsIdeaScope(appStoreId: 99, country: "US")]
            try await repo.replace(adAccountId: 42, from: Self.day(1), to: Self.day(1), with: second)
            let texts = Set(try await repo.ideas(adAccountId: 42, appStoreId: 99).map(\.text))
            #expect(texts == ["old us", "new de"])
        }
    }
}

