@testable import App
import Foundation
import Testing
import Vapor

@Suite("Apple Ads insights: overview and keywords")
struct AppleAdsInsightsServiceTests {
    static let app = AppleAdsFixtures.ownApp

    struct Harness {
        let service: AppleAdsInsightsService
        let repo: InMemoryAppleAdsDataRepository
        let ranks: InMemoryRankCheckRepository
    }

    static func harness(running: Bool = false, tracked: [Keyword] = []) -> Harness {
        let repo = InMemoryAppleAdsDataRepository()
        let ranks = InMemoryRankCheckRepository()
        let service = AppleAdsInsightsService(
            repository: repo,
            watchedApps: InMemoryWatchedAppRepository([app]),
            keywords: InMemoryKeywordRepository(tracked),
            rankChecks: ranks,
            syncRunning: { running },
            today: { "2026-11-06" }
        )
        return Harness(service: service, repo: repo, ranks: ranks)
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

    @Test("the sync's last day is still partial, so periods end the day before")
    func periodExcludesPartialLastDay() async throws {
        let h = Self.harness()
        var snapshot = AppleAdsSnapshot()
        snapshot.campaigns = [AppleAdsFixtures.campaign]
        snapshot.campaignDays = [
            Self.day(1, "2026-11-06", taps: 5, installs: 0, spend: 1),  // synced on its own day: partial
            Self.day(1, "2026-11-05", taps: 100, installs: 4, spend: 20),
        ]
        try await Self.synced(h.repo, snapshot)
        let o = try await h.service.overview(watchedAppId: Self.app.id!, days: 7)
        #expect(o.to == "2026-11-05")
        #expect(o.totals.taps == 100)
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

    // MARK: Keywords

    static let flashcards = AppleAdsKeywordInfo(id: 5, campaignId: 1, adGroupId: 2, text: "Flashcards", matchType: "EXACT", status: "ACTIVE", bid: 1.5, currency: "USD")

    static func keywordDay(_ country: String, _ date: String, taps: Int, installs: Int, spend: Double, suggested: Double? = nil, keyword: Int64 = 5, campaign: Int64 = 1) -> AppleAdsKeywordDay {
        AppleAdsKeywordDay(keywordId: keyword, campaignId: campaign, country: country, date: date, metrics: AppleAdsFixtures.metrics(taps: taps, installs: installs, spend: spend), suggestedBid: suggested)
    }

    static func keywordSnapshot(_ days: [AppleAdsKeywordDay]) -> AppleAdsSnapshot {
        var snapshot = AppleAdsSnapshot()
        let other = AppleAdsCampaignInfo(id: 2, appStoreId: 555, name: "Other app", status: "RUNNING", countries: ["US"], dailyBudget: 5, currency: "USD")
        snapshot.campaigns = [AppleAdsFixtures.campaign, other]
        snapshot.keywords = [flashcards, AppleAdsKeywordInfo(id: 9, campaignId: 2, adGroupId: 3, text: "other", matchType: "BROAD", status: "ACTIVE", bid: 1, currency: "USD")]
        snapshot.campaignDays = [Self.day(1, "2026-11-05", taps: 1, installs: 0, spend: 1)]
        snapshot.keywordDays = days
        return snapshot
    }

    @Test("keyword rows sum the period per country, this app only, by spend")
    func keywordRowsSumPeriodPerCountry() async throws {
        let h = Self.harness()
        try await Self.synced(h.repo, Self.keywordSnapshot([
            Self.keywordDay("US", "2026-11-05", taps: 60, installs: 3, spend: 9),
            Self.keywordDay("US", "2026-11-01", taps: 40, installs: 2, spend: 6),
            Self.keywordDay("US", "2026-10-01", taps: 999, installs: 9, spend: 99), // outside 7 days
            Self.keywordDay("DE", "2026-11-04", taps: 5, installs: 0, spend: 2),
            Self.keywordDay("US", "2026-11-05", taps: 70, installs: 7, spend: 50, keyword: 9, campaign: 2),
        ]))
        let rows = try await h.service.keywords(watchedAppId: Self.app.id!, days: 7)
        #expect(rows.map(\.country) == ["US", "DE"])
        let us = try #require(rows.first)
        #expect(us.keywordId == "5")
        #expect(us.text == "Flashcards")
        #expect(us.campaignName == "US Search")
        #expect(us.bid == 1.5)
        #expect(us.currency == "USD")
        #expect(us.metrics.taps == 100)
        #expect(us.metrics.spend == 15)
        #expect(us.metrics.cpi == 3)
    }

    @Test("organic rank comes from the tracked keyword in the same country")
    func organicRankMatchesCountry() async throws {
        let us = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let de = Keyword(id: UUID(), term: "Flashcards", countryCode: "de")
        let h = Self.harness(tracked: [us, de])
        try await h.ranks.save(RankCheck(keywordID: us.id!, watchedAppID: Self.app.id!, rank: 3, difficulty: 50, entryBarrier: 50, checkedAt: Date()))
        try await h.ranks.save(RankCheck(keywordID: de.id!, watchedAppID: Self.app.id!, rank: 40, difficulty: 50, entryBarrier: 50, checkedAt: Date()))
        try await Self.synced(h.repo, Self.keywordSnapshot([
            Self.keywordDay("US", "2026-11-05", taps: 60, installs: 3, spend: 9),
            Self.keywordDay("DE", "2026-11-05", taps: 5, installs: 0, spend: 2),
        ]))
        let rows = try await h.service.keywords(watchedAppId: Self.app.id!, days: 7)
        let usRow = try #require(rows.first { $0.country == "US" })
        let deRow = try #require(rows.first { $0.country == "DE" })
        #expect(usRow.organicRank == 3)
        #expect(usRow.alreadyRanksWell)
        #expect(usRow.trackedKeywordId == us.id)
        #expect(deRow.organicRank == 40)
        #expect(!deRow.alreadyRanksWell)
    }

    @Test("a keyword that isn't tracked has no organic rank")
    func untrackedKeywordHasNoRank() async throws {
        let h = Self.harness(tracked: [Keyword(id: UUID(), term: "flashcards", countryCode: "gb")])
        try await Self.synced(h.repo, Self.keywordSnapshot([Self.keywordDay("US", "2026-11-05", taps: 60, installs: 3, spend: 9)]))
        let row = try #require(try await h.service.keywords(watchedAppId: Self.app.id!, days: 7).first)
        #expect(row.organicRank == nil)
        #expect(row.trackedKeywordId == nil)
        #expect(!row.alreadyRanksWell)
    }

    @Test("the suggested bid is the most recent one Apple gave in the period")
    func suggestedBidIsLatestDays() async throws {
        let h = Self.harness()
        try await Self.synced(h.repo, Self.keywordSnapshot([
            Self.keywordDay("US", "2026-11-01", taps: 10, installs: 1, spend: 1, suggested: 1.1),
            Self.keywordDay("US", "2026-11-03", taps: 10, installs: 1, spend: 1, suggested: 1.4),
            Self.keywordDay("US", "2026-11-05", taps: 10, installs: 1, spend: 1, suggested: nil),
        ]))
        let row = try #require(try await h.service.keywords(watchedAppId: Self.app.id!, days: 7).first)
        #expect(row.suggestedBid == 1.4)
    }

    // MARK: Bid ideas

    static func term(_ text: String, _ country: String = "US", taps: Int, installs: Int, spend: Double = 1, campaign: Int64 = 1, date: String = "2026-11-05") -> AppleAdsSearchTermDay {
        AppleAdsSearchTermDay(campaignId: campaign, adGroupId: 2, keywordId: nil, term: text, source: "AUTO", country: country, date: date, metrics: AppleAdsFixtures.metrics(taps: taps, installs: installs, spend: spend))
    }

    static func ideasSnapshot(terms: [AppleAdsSearchTermDay] = [], ideas: [AppleAdsKeywordIdea] = [], popularity: [AppleAdsTermPopularity] = []) -> AppleAdsSnapshot {
        var snapshot = keywordSnapshot([])
        snapshot.keywords[0] = AppleAdsKeywordInfo(id: 5, campaignId: 1, adGroupId: 2, text: "flashcards", matchType: "EXACT", status: "ACTIVE", bid: 1.5, currency: "USD")
        snapshot.keywords.append(AppleAdsKeywordInfo(id: 6, campaignId: 1, adGroupId: 2, text: "study cards", matchType: "BROAD", status: "ACTIVE", bid: 1, currency: "USD"))
        snapshot.searchTermDays = terms
        snapshot.ideas = ideas
        snapshot.popularity = popularity
        return snapshot
    }

    @Test("converted terms leave out ones already bid as exact match")
    func convertedExcludesExactBidTerms() async throws {
        let h = Self.harness()
        try await Self.synced(h.repo, Self.ideasSnapshot(terms: [
            Self.term("flashcards app", taps: 20, installs: 1, date: "2026-11-04"),
            Self.term("flashcards app", taps: 20, installs: 1),
            Self.term("Flashcards", taps: 30, installs: 3),
            Self.term("no installs", taps: 30, installs: 0),
            Self.term("LOW_VOLUME", taps: 30, installs: 9),
            Self.term("other app term", taps: 30, installs: 9, campaign: 2),
        ]))
        let ideas = try await h.service.bidIdeas(watchedAppId: Self.app.id!, days: 30)
        #expect(ideas.converted.map(\.term) == ["flashcards app"])
        #expect(ideas.converted.first?.metrics?.tapInstalls == 2)
        #expect(ideas.converted.first?.country == "US")
        #expect(ideas.currency == "USD")
    }

    @Test("wasted spend needs at least 50 taps and no installs")
    func wastedNeeds50TapsAndZeroInstalls() async throws {
        let h = Self.harness()
        try await Self.synced(h.repo, Self.ideasSnapshot(terms: [
            Self.term("almost", taps: 49, installs: 0, spend: 30),
            Self.term("cheap waste", taps: 50, installs: 0, spend: 10),
            Self.term("big waste", taps: 80, installs: 0, spend: 40),
            Self.term("converts", taps: 80, installs: 1, spend: 40),
        ]))
        let ideas = try await h.service.bidIdeas(watchedAppId: Self.app.id!, days: 30)
        #expect(ideas.wasted.map(\.term) == ["big waste", "cheap waste"])
    }

    @Test("ideas carry popularity, organic rank and difficulty when known")
    func ideasCarryPopularityRankAndDifficulty() async throws {
        let tracked = Keyword(id: UUID(), term: "flashcards app", countryCode: "us")
        let h = Self.harness(tracked: [tracked])
        try await h.ranks.save(RankCheck(keywordID: tracked.id!, watchedAppID: Self.app.id!, rank: 12, difficulty: 64, entryBarrier: 40, checkedAt: Date()))
        try await Self.synced(h.repo, Self.ideasSnapshot(
            terms: [Self.term("flashcards app", taps: 20, installs: 2)],
            popularity: [AppleAdsTermPopularity(term: "flashcards app", country: "US", genre: "EDUCATION", week: "2026-10-25", popularity100: 37, popularity5: 2, rankInGenre: 80)]
        ))
        let idea = try #require(try await h.service.bidIdeas(watchedAppId: Self.app.id!, days: 30).converted.first)
        #expect(idea.popularity == 37)
        #expect(idea.organicRank == 12)
        #expect(idea.difficulty == 64)
        #expect(idea.trackedKeywordId == tracked.id)
    }

    @Test("Apple's suggestions leave out keywords already bid in that country")
    func suggestionsExcludeBidKeywords() async throws {
        let h = Self.harness()
        try await Self.synced(h.repo, Self.ideasSnapshot(ideas: [
            AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "Study Cards", popularity: 3),
            AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "memory game", popularity: 2),
            AppleAdsKeywordIdea(appStoreId: 99, country: "DE", text: "flashcards", popularity: 4),
            AppleAdsKeywordIdea(appStoreId: 555, country: "US", text: "other app idea", popularity: 4),
        ]))
        let ideas = try await h.service.bidIdeas(watchedAppId: Self.app.id!, days: 30)
        // The campaign serves US only, so "flashcards" is not bid in DE.
        #expect(Set(ideas.suggestions.map { "\($0.term)|\($0.country)" }) == ["memory game|US", "flashcards|DE"])
        #expect(ideas.suggestions.allSatisfy { $0.metrics == nil })
    }
}

