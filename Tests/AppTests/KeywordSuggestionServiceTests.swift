@testable import App
import Foundation
import Logging
import Testing

@Suite("KeywordSuggestionService")
struct KeywordSuggestionServiceTests {
    @Test("returns [] when ASA credentials are not configured")
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
        #expect(result.isEmpty)
    }

    @Test("returns [] when no campaign serves the seed's storefront")
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
        #expect(result.isEmpty, "no US campaign → no suggestions for a US seed")
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
                            // Should be filtered out — seed substring missing.
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

        #expect(result.count == 2, "irrelevant 'tiktok' filtered out, dupe collapsed")
        // Sorted by impressions desc — anki flashcards has 100+50=150 impressions.
        #expect(result[0].term == "anki flashcards")
        #expect(result[0].impressions == 150)
        #expect(result[0].taps == 15)
        #expect(result[0].alreadyTracked == true)
        // Second row is the untracked term.
        #expect(result[1].term == untracked)
        #expect(result[1].alreadyTracked == false)
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
