@testable import App
import Foundation
import Logging
import Testing

@Suite("KeywordSuggestionService")
struct KeywordSuggestionServiceTests {
    private static let creds = ASACredentials(clientId: "c", clientSecret: "j", orgId: nil)

    private static func service(
        asa: ASACredentials? = creds,
        keywords: [Keyword],
        mirror: InMemoryAppleAdsDataRepository
    ) -> KeywordSuggestionService {
        KeywordSuggestionService(
            settings: StubSettingsService(asa: asa),
            keywordRepo: InMemoryKeywordRepository(keywords),
            rankCheckRepo: InMemoryRankCheckRepository(),
            mirror: mirror,
            today: { "2026-11-06" }
        )
    }

    @Test("returns empty response when ASA credentials are not configured")
    func empty_whenNoCreds() async throws {
        let result = try await Self.service(asa: nil, keywords: [], mirror: InMemoryAppleAdsDataRepository())
            .suggest(seedKeywordId: UUID())
        #expect(result.rows.isEmpty)
        #expect(result.anonymized == nil)
    }

    @Test("returns empty response when no search terms come from the seed's storefront")
    func empty_whenNoMatchingCampaign() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([
            ("flashcards jp", "JP", 1, 100, 10, "AUTO"),
        ]))
        let result = try await Self.service(keywords: [seed], mirror: mirror).suggest(seedKeywordId: seed.id!)
        #expect(result.rows.isEmpty, "only JP terms → no suggestions for a US seed")
        #expect(result.anonymized == nil)
    }

    @Test("reads the synced search terms: filters to seed-related terms, dedupes across campaigns, marks alreadyTracked")
    func suggestionServiceReadsMirror() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let trackedAlready = Keyword(id: UUID(), term: "anki flashcards", countryCode: "us")
        let untracked = "best flashcards 2026"
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([
            ("anki flashcards", "US", 1, 100, 10, "AUTO"),
            (untracked, "US", 1, 50, 5, "AUTO"),
            // Should be filtered out — no token overlap with "flashcards".
            ("tiktok video maker", "US", 1, 999, 0, "AUTO"),
            // Same term in two campaigns → must dedupe with sums.
            ("anki flashcards", "US", 2, 50, 5, "AUTO"),
            // Another storefront's row for the same term doesn't count.
            ("anki flashcards", "DE", 1, 7000, 70, "AUTO"),
        ]))

        let result = try await Self.service(keywords: [seed, trackedAlready], mirror: mirror).suggest(seedKeywordId: seed.id!)
        let rows = result.rows

        #expect(rows.count == 2, "irrelevant 'tiktok' filtered out, dupe collapsed")
        // "anki flashcards" has higher Jaccard against seed "flashcards"
        // (1/2 = 0.5) than "best flashcards 2026" (1/4 = 0.25), so it
        // wins on relevance even before the impression tiebreaker.
        #expect(rows[0].term == "anki flashcards")
        #expect(rows[0].impressions == 150)
        #expect(rows[0].taps == 15)
        #expect(rows[0].alreadyTracked == true)
        // Second row is the untracked term.
        #expect(rows[1].term == untracked)
        #expect(rows[1].alreadyTracked == false)
        #expect(result.anonymized == nil)
    }

    @Test("keeps token-overlap matches that substring containment would drop")
    func tokenOverlap_keepsRelatedNonSubstrings() async throws {
        // Real ASA shape: seed = "flashcard maker" (two tokens). The user's
        // broad-match auctions surface "best flashcard maker" — a row that
        // shares the seed's two tokens but isn't a substring of either side.
        let seed = Keyword(id: UUID(), term: "flashcard maker", countryCode: "us")
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([
            // Kept: shares both seed tokens, Jaccard 2/3.
            ("best flashcard maker", "US", 1, 30, 3, "AUTO"),
            // Kept: shares the long "flashcard" token.
            ("anki flashcard app", "US", 1, 20, 2, "AUTO"),
            // Dropped: no shared tokens.
            ("spaced repetition app", "US", 1, 100, 0, "AUTO"),
        ]))

        let result = try await Self.service(keywords: [seed], mirror: mirror).suggest(seedKeywordId: seed.id!)
        let terms = result.rows.map(\.term)
        #expect(terms.contains("best flashcard maker"))
        #expect(terms.contains("anki flashcard app"))
        #expect(!terms.contains("spaced repetition app"), "no token overlap → dropped")
        // Higher Jaccard (2/3) wins over (1/4) on relevance even though
        // impressions are smaller — that's the whole point of the sort.
        #expect(result.rows.first?.term == "best flashcard maker")
    }

    @Test("aggregates LOW_VOLUME placeholder rows into the anonymized summary")
    func lowVolume_aggregated() async throws {
        // Two campaigns, each emitting a LOW_VOLUME row plus one real row.
        let seed = Keyword(id: UUID(), term: "anki", countryCode: "gb")
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([
            ("LOW_VOLUME", "GB", 1, 20, 0, "AUTO"),
            // Real "anki" exact-match row: visible signal.
            ("anki", "GB", 1, 49, 4, "TARGETED"),
            ("LOW_VOLUME", "GB", 2, 4, 0, "AUTO"),
        ]))

        let result = try await Self.service(keywords: [seed], mirror: mirror).suggest(seedKeywordId: seed.id!)

        // 20 + 4 = 24 impressions across 2 campaign × ad group sources.
        #expect(result.anonymized != nil)
        #expect(result.anonymized?.impressions == 24)
        #expect(result.anonymized?.taps == 0)
        #expect(result.anonymized?.sourceCount == 2)

        // The real "anki" row survives the relevance filter.
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.term == "anki")
        #expect(result.rows.first?.impressions == 49)
    }

    @Test("rows older than 30 days before the newest synced day are left out")
    func onlyLast30Days() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let mirror = InMemoryAppleAdsDataRepository()
        var snapshot = AppleAdsMirrorSeed.searchTerms([("flashcards app", "US", 1, 100, 10, "AUTO")])
        snapshot.searchTermDays += AppleAdsMirrorSeed.searchTerms([("flashcards old", "US", 1, 100, 10, "AUTO")], date: "2026-10-06").searchTermDays
        try await AppleAdsMirrorSeed.synced(mirror, snapshot)
        let result = try await Self.service(keywords: [seed], mirror: mirror).suggest(seedKeywordId: seed.id!)
        #expect(result.rows.map(\.term) == ["flashcards app"])
    }

    @Test("before any sync there are no suggestions")
    func emptyBeforeFirstSync() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let result = try await Self.service(keywords: [seed], mirror: InMemoryAppleAdsDataRepository()).suggest(seedKeywordId: seed.id!)
        #expect(result.rows.isEmpty)
    }

    @Test("a failed last sync with nothing synced surfaces the sync's error")
    func failedLastSyncWithoutDataThrowsSyncFailed() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let mirror = InMemoryAppleAdsDataRepository()
        await AppleAdsMirrorSeed.failedRun(mirror, error: "Apple Ads returned HTTP 500.")
        await #expect(throws: AppleAdsError.syncFailed("Apple Ads returned HTTP 500.")) {
            _ = try await Self.service(keywords: [seed], mirror: mirror).suggest(seedKeywordId: seed.id!)
        }
        #expect(AppleAdsError.syncFailed("x").description == "The last Apple Ads sync failed: x")
    }

    // MARK: - Pure-function coverage for the relevance helpers

    @Test("tokenize splits on whitespace and trims light punctuation")
    func tokenize_basic() {
        #expect(KeywordSuggestionService.tokenize("anki flashcards") == ["anki", "flashcards"])
        #expect(KeywordSuggestionService.tokenize("BEST  FLASHCARD MAKER!") == ["best", "flashcard", "maker"])
        #expect(KeywordSuggestionService.tokenize("") == [])
        #expect(KeywordSuggestionService.tokenize("  ") == [])
    }

    @Test("score returns Jaccard and the long-shared-token flag")
    func score_basic() {
        // Disjoint sets → (0, false).
        let disjoint = KeywordSuggestionService.score(
            seedTokens: ["anki"],
            termTokens: ["spaced", "repetition"]
        )
        #expect(disjoint.jaccard == 0)
        #expect(disjoint.hasLongShared == false)

        // Shared long token → long-shared flag set, Jaccard 1/2.
        let oneShared = KeywordSuggestionService.score(
            seedTokens: ["anki"],
            termTokens: ["anki", "desktop"]
        )
        #expect(oneShared.jaccard == 0.5)
        #expect(oneShared.hasLongShared == true)

        // Shared but short token → long-shared flag false.
        let shortShared = KeywordSuggestionService.score(
            seedTokens: ["the", "app"],
            termTokens: ["the", "guide"]
        )
        #expect(shortShared.hasLongShared == false)
    }
}

// ── Local stubs (file-private to avoid cross-test pollution) ────────────

private actor StubSettingsService: SettingsServiceProtocol {
    let asa: ASACredentials?
    init(asa: ASACredentials?) { self.asa = asa }

    func getASCStatus() async throws -> ASCStatus {
        ASCStatus(keyId: nil, issuerId: nil, hasPrivateKey: false)
    }
    func getASCCredentials() async throws -> ASCCredentials? { nil }
    func setASCCredentials(_ creds: ASCCredentials) async throws {}
    func clearASCCredentials() async throws {}
    func getASAStatus() async throws -> ASAStatus {
        ASAStatus(clientId: asa?.clientId, orgId: asa?.orgId, hasClientSecret: asa != nil)
    }
    func getASACredentials() async throws -> ASACredentials? { asa }
    func setASACredentials(_ creds: ASACredentials) async throws {}
    func clearASACredentials() async throws {}
}
