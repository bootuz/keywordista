@testable import App
import Foundation
import Logging
import Testing

@Suite("KeywordSuggestionService")
struct KeywordSuggestionServiceTests {
    @Test("returns empty response when ASA credentials are not configured")
    func empty_whenNoCreds() async throws {
        let service = KeywordSuggestionService(
            settings: StubSettingsService(asa: nil),
            keywordRepo: InMemoryKeywordRepository([]),
            rankCheckRepo: InMemoryRankCheckRepository(),
            makeClient: { _ in FailingASAClient() },
            now: { Date(timeIntervalSince1970: 0) },
            logger: Logger(label: "t")
        )
        let result = try await service.suggest(seedKeywordId: UUID())
        #expect(result.rows.isEmpty)
        #expect(result.anonymized == nil)
    }

    @Test("returns empty response when no campaign serves the seed's storefront")
    func empty_whenNoMatchingCampaign() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let service = KeywordSuggestionService(
            settings: StubSettingsService(asa: .init(clientId: "c", clientSecret: "j", orgId: nil)),
            keywordRepo: InMemoryKeywordRepository([seed]),
            rankCheckRepo: InMemoryRankCheckRepository(),
            makeClient: { _ in
                StubASAClient(
                    campaigns: [ASACampaign(id: 1, name: "JP-only", countriesOrRegions: ["JP"], displayStatus: "RUNNING")],
                    searchTermsByCampaign: [:]
                )
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logger: Logger(label: "t")
        )
        let result = try await service.suggest(seedKeywordId: seed.id!)
        #expect(result.rows.isEmpty, "no US campaign → no suggestions for a US seed")
        #expect(result.anonymized == nil)
    }

    @Test("filters to seed-related terms, dedupes across campaigns, marks alreadyTracked")
    func happyPath() async throws {
        let seed = Keyword(id: UUID(), term: "flashcards", countryCode: "us")
        let trackedAlready = Keyword(id: UUID(), term: "anki flashcards", countryCode: "us")
        let untracked = "best flashcards 2026"

        let service = KeywordSuggestionService(
            settings: StubSettingsService(asa: .init(clientId: "c", clientSecret: "j", orgId: nil)),
            keywordRepo: InMemoryKeywordRepository([seed, trackedAlready]),
            rankCheckRepo: InMemoryRankCheckRepository(),
            makeClient: { _ in
                StubASAClient(
                    campaigns: [
                        ASACampaign(id: 1, name: "US-A", countriesOrRegions: ["US"], displayStatus: "RUNNING"),
                        ASACampaign(id: 2, name: "US-B", countriesOrRegions: ["US"], displayStatus: "RUNNING"),
                    ],
                    searchTermsByCampaign: [
                        1: [
                            ASASearchTerm(text: "anki flashcards", source: "AUTO",
                                          impressions: 100, taps: 10, ttr: 0.10, localSpend: 5),
                            ASASearchTerm(text: untracked, source: "AUTO",
                                          impressions: 50, taps: 5, ttr: 0.10, localSpend: 3),
                            // Should be filtered out — no token overlap with "flashcards".
                            ASASearchTerm(text: "tiktok video maker", source: "AUTO",
                                          impressions: 999, taps: 0, ttr: 0, localSpend: 0),
                        ],
                        2: [
                            // Same term in two campaigns → must dedupe with sums.
                            ASASearchTerm(text: "anki flashcards", source: "AUTO",
                                          impressions: 50, taps: 5, ttr: 0.10, localSpend: 2),
                        ],
                    ]
                )
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logger: Logger(label: "t")
        )

        let result = try await service.suggest(seedKeywordId: seed.id!)
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
        // The pre-fix substring filter dropped these silently; the
        // token-overlap rule keeps them.
        let seed = Keyword(id: UUID(), term: "flashcard maker", countryCode: "us")

        let service = KeywordSuggestionService(
            settings: StubSettingsService(asa: .init(clientId: "c", clientSecret: "j", orgId: nil)),
            keywordRepo: InMemoryKeywordRepository([seed]),
            rankCheckRepo: InMemoryRankCheckRepository(),
            makeClient: { _ in
                StubASAClient(
                    campaigns: [
                        ASACampaign(id: 1, name: "US-A", countriesOrRegions: ["US"], displayStatus: "RUNNING"),
                    ],
                    searchTermsByCampaign: [
                        1: [
                            // Kept: shares both seed tokens, Jaccard 2/3.
                            ASASearchTerm(text: "best flashcard maker", source: "AUTO",
                                          impressions: 30, taps: 3, ttr: 0.10, localSpend: 2),
                            // Kept: shares the long "flashcard" token.
                            ASASearchTerm(text: "anki flashcard app", source: "AUTO",
                                          impressions: 20, taps: 2, ttr: 0.10, localSpend: 1),
                            // Dropped: no shared tokens.
                            ASASearchTerm(text: "spaced repetition app", source: "AUTO",
                                          impressions: 100, taps: 0, ttr: 0, localSpend: 0),
                        ],
                    ]
                )
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logger: Logger(label: "t")
        )

        let result = try await service.suggest(seedKeywordId: seed.id!)
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
        // Reproduces the user's actual GB campaign shape: two campaigns,
        // each emitting a LOW_VOLUME row plus one real row. Before the
        // fix, the substring filter dropped both LOW_VOLUME rows AND any
        // real row that didn't contain the seed.
        let seed = Keyword(id: UUID(), term: "anki", countryCode: "gb")

        let service = KeywordSuggestionService(
            settings: StubSettingsService(asa: .init(clientId: "c", clientSecret: "j", orgId: nil)),
            keywordRepo: InMemoryKeywordRepository([seed]),
            rankCheckRepo: InMemoryRankCheckRepository(),
            makeClient: { _ in
                StubASAClient(
                    campaigns: [
                        ASACampaign(id: 1, name: "anki-EXACT", countriesOrRegions: ["GB"], displayStatus: "RUNNING"),
                        ASACampaign(id: 2, name: "flashcard-BROAD", countriesOrRegions: ["GB"], displayStatus: "RUNNING"),
                    ],
                    searchTermsByCampaign: [
                        1: [
                            ASASearchTerm(text: "LOW_VOLUME", source: "AUTO",
                                          impressions: 20, taps: 0, ttr: 0, localSpend: 1),
                            // Real "anki" exact-match row: visible signal.
                            ASASearchTerm(text: "anki", source: "TARGETED",
                                          impressions: 49, taps: 4, ttr: 0.08, localSpend: 4),
                        ],
                        2: [
                            ASASearchTerm(text: "LOW_VOLUME", source: "AUTO",
                                          impressions: 4, taps: 0, ttr: 0, localSpend: 1),
                        ],
                    ]
                )
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            logger: Logger(label: "t")
        )

        let result = try await service.suggest(seedKeywordId: seed.id!)

        // Anonymized totals match the user's CSV: 20 + 4 = 24 impressions
        // across 2 campaign × match-type combos.
        #expect(result.anonymized != nil)
        #expect(result.anonymized?.impressions == 24)
        #expect(result.anonymized?.taps == 0)
        #expect(result.anonymized?.sourceCount == 2)

        // The real "anki" row survives the relevance filter.
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.term == "anki")
        #expect(result.rows.first?.impressions == 49)
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

private actor StubASAClient: AppleSearchAdsClientProtocol {
    let campaigns: [ASACampaign]
    let searchTermsByCampaign: [Int64: [ASASearchTerm]]

    init(campaigns: [ASACampaign], searchTermsByCampaign: [Int64: [ASASearchTerm]]) {
        self.campaigns = campaigns
        self.searchTermsByCampaign = searchTermsByCampaign
    }

    func listCampaigns() async throws -> [ASACampaign] { campaigns }

    func searchTermsReport(campaignId: Int64, startDate: Date, endDate: Date) async throws -> [ASASearchTerm] {
        searchTermsByCampaign[campaignId] ?? []
    }
}

private struct FailingASAClient: AppleSearchAdsClientProtocol {
    func listCampaigns() async throws -> [ASACampaign] {
        throw AppleSearchAdsClient.Failure.invalidCredentials
    }
    func searchTermsReport(campaignId: Int64, startDate: Date, endDate: Date) async throws -> [ASASearchTerm] {
        throw AppleSearchAdsClient.Failure.invalidCredentials
    }
}
