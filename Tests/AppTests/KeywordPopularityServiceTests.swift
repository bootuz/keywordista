@testable import App
import Foundation
import Logging
import Testing

@Suite("KeywordPopularityService")
struct KeywordPopularityServiceTests {
    private func makeService(asa: ASACredentials?, keywords: [Keyword], mirror: InMemoryAppleAdsDataRepository) -> KeywordPopularityService {
        KeywordPopularityService(
            settings: StubASASettings(asa: asa),
            keywordRepo: InMemoryKeywordRepository(keywords),
            mirror: mirror,
            today: { "2026-11-06" }
        )
    }

    @Test("maps synced search-term impressions onto tracked keywords by (term, country); ignores LOW_VOLUME and unmatched")
    func popularityServiceReadsMirror() async throws {
        let kwUS = UUID()
        let kwUSUntracked = UUID()
        let kwDE = UUID()
        let keywords = [
            Keyword(id: kwUS, term: "flashcards", countryCode: "us"),
            Keyword(id: kwUSUntracked, term: "obscure term", countryCode: "us"),  // no ASA data
            Keyword(id: kwDE, term: "karteikarten", countryCode: "de"),
        ]
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([
            ("flashcards", "US", 1, 900, 30, "AUTO"),
            ("Flashcards", "US", 2, 100, 5, "TARGETED"), // same term, 2nd campaign → sums to 1000
            ("LOW_VOLUME", "US", 1, 50, 0, "AUTO"),       // ignored
            ("karteikarten", "DE", 3, 400, 12, "AUTO"),
        ]))

        let pop = try await makeService(asa: .stub, keywords: keywords, mirror: mirror).popularity()

        #expect(pop[kwUS] == 1000)            // summed across the two US rows
        #expect(pop[kwDE] == 400)
        #expect(pop[kwUSUntracked] == nil)    // tracked but no ASA data → no signal
        #expect(pop.count == 2)
    }

    @Test("a US term's impressions don't leak to a same-term keyword tracked in another country")
    func countryScoped() async throws {
        let kwDE = UUID()
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([("flashcards", "US", 1, 900, 30, "AUTO")]))
        let pop = try await makeService(asa: .stub, keywords: [Keyword(id: kwDE, term: "flashcards", countryCode: "de")], mirror: mirror).popularity()
        #expect(pop[kwDE] == nil)  // US impressions must not count for a DE keyword
    }

    @Test("returns empty when ASA is not configured")
    func noASA() async throws {
        let mirror = InMemoryAppleAdsDataRepository()
        try await AppleAdsMirrorSeed.synced(mirror, AppleAdsMirrorSeed.searchTerms([("flashcards", "US", 1, 900, 30, "AUTO")]))
        let service = makeService(asa: nil, keywords: [Keyword(id: UUID(), term: "flashcards", countryCode: "us")], mirror: mirror)
        #expect(try await service.popularity().isEmpty)
    }

    @Test("a failed last sync with nothing synced surfaces the sync's error")
    func failedLastSyncThrows() async throws {
        let mirror = InMemoryAppleAdsDataRepository()
        await AppleAdsMirrorSeed.failedRun(mirror, error: "boom")
        let service = makeService(asa: .stub, keywords: [Keyword(id: UUID(), term: "flashcards", countryCode: "us")], mirror: mirror)
        await #expect(throws: AppleAdsError.syncFailed("boom")) { _ = try await service.popularity() }
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
