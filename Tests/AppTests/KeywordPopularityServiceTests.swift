@testable import App
import Foundation
import Logging
import Testing

@Suite("KeywordPopularityService")
struct KeywordPopularityServiceTests {
    private func makeService(
        asa: ASACredentials?,
        keywords: [Keyword],
        campaigns: [ASACampaign],
        searchTerms: [Int64: [ASASearchTerm]],
    ) -> KeywordPopularityService {
        KeywordPopularityService(
            settings: StubASASettings(asa: asa),
            keywordRepo: InMemoryKeywordRepository(keywords),
            makeClient: { _ in StubASAClientP(campaigns: campaigns, searchTermsByCampaign: searchTerms) },
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            logger: Logger(label: "test"),
        )
    }

    @Test("maps ASA impressions onto tracked keywords by (term, country); ignores LOW_VOLUME and unmatched")
    func mapsImpressions() async throws {
        let kwUS = UUID()
        let kwUSUntracked = UUID()
        let kwDE = UUID()
        let keywords = [
            Keyword(id: kwUS, term: "flashcards", countryCode: "us"),
            Keyword(id: kwUSUntracked, term: "obscure term", countryCode: "us"),  // no ASA data
            Keyword(id: kwDE, term: "karteikarten", countryCode: "de"),
        ]
        let campaigns = [
            ASACampaign(id: 1, name: "US", countriesOrRegions: ["US"], displayStatus: "RUNNING"),
            ASACampaign(id: 2, name: "DE", countriesOrRegions: ["DE"], displayStatus: "RUNNING"),
        ]
        let terms: [Int64: [ASASearchTerm]] = [
            1: [
                .init(text: "flashcards", source: "AUTO", impressions: 900, taps: 30, ttr: 0.03, localSpend: 0),
                .init(text: "flashcards", source: "TARGETED", impressions: 100, taps: 5, ttr: 0.05, localSpend: 0), // same term, 2nd campaign row → sums to 1000
                .init(text: "LOW_VOLUME", source: "AUTO", impressions: 50, taps: 0, ttr: 0, localSpend: 0),         // ignored
            ],
            2: [
                .init(text: "karteikarten", source: "AUTO", impressions: 400, taps: 12, ttr: 0.03, localSpend: 0),
            ],
        ]

        let service = makeService(asa: .stub, keywords: keywords, campaigns: campaigns, searchTerms: terms)
        let pop = try await service.popularity()

        #expect(pop[kwUS] == 1000)            // summed across the two US rows
        #expect(pop[kwDE] == 400)
        #expect(pop[kwUSUntracked] == nil)    // tracked but no ASA data → no signal
        #expect(pop.count == 2)
    }

    @Test("a US term's impressions don't leak to a same-term keyword tracked in another country")
    func countryScoped() async throws {
        let kwDE = UUID()
        let keywords = [Keyword(id: kwDE, term: "flashcards", countryCode: "de")]
        let campaigns = [ASACampaign(id: 1, name: "US", countriesOrRegions: ["US"], displayStatus: "RUNNING")]
        let terms: [Int64: [ASASearchTerm]] = [
            1: [.init(text: "flashcards", source: "AUTO", impressions: 900, taps: 30, ttr: 0.03, localSpend: 0)],
        ]
        let service = makeService(asa: .stub, keywords: keywords, campaigns: campaigns, searchTerms: terms)
        let pop = try await service.popularity()
        #expect(pop[kwDE] == nil)  // US impressions must not count for a DE keyword
    }

    @Test("returns empty when ASA is not configured")
    func noASA() async throws {
        let service = makeService(
            asa: nil,
            keywords: [Keyword(id: UUID(), term: "flashcards", countryCode: "us")],
            campaigns: [],
            searchTerms: [:],
        )
        #expect(try await service.popularity().isEmpty)
    }
}

private extension ASACredentials {
    static var stub: ASACredentials {
        ASACredentials(clientId: "c", clientSecret: "s", orgId: "1")
    }
}

private actor StubASASettings: SettingsServiceProtocol {
    let asa: ASACredentials?
    init(asa: ASACredentials?) { self.asa = asa }
    func getASCStatus() async throws -> ASCStatus { ASCStatus(keyId: nil, issuerId: nil, hasPrivateKey: false) }
    func getASCCredentials() async throws -> ASCCredentials? { nil }
    func setASCCredentials(_ creds: ASCCredentials) async throws {}
    func clearASCCredentials() async throws {}
    func getASAStatus() async throws -> ASAStatus { ASAStatus(clientId: asa?.clientId, orgId: asa?.orgId, hasClientSecret: asa != nil) }
    func getASACredentials() async throws -> ASACredentials? { asa }
    func setASACredentials(_ creds: ASACredentials) async throws {}
    func clearASACredentials() async throws {}
}

private actor StubASAClientP: AppleSearchAdsClientProtocol {
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
