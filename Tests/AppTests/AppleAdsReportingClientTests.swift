@testable import App
import AppleAdsClient
import Foundation
import HTTPTypes
import Logging
import Testing

@Suite("Apple Ads reporting reads (Platform API v1)")
struct AppleAdsReportingClientTests {

    private static func makeClient(_ transport: StubAppleAdsTransport) -> (AppleAdsPlatformClient, AppleAdsSession) {
        let session = AppleAdsSession(logger: Logger(label: "t")) { _ in
            try await makeTestAppleAdsClient(transport: transport, middleware: [AppleAdsRetryMiddleware(sleep: { _ in })])
        }
        let creds = ASACredentials(clientId: "SEARCHADS.t", clientSecret: "jwt", orgId: nil, adAccountId: "42")
        return (AppleAdsPlatformClient(credentials: creds, session: session, logger: Logger(label: "t")), session)
    }

    private static func body(_ request: StubAppleAdsTransport.Recorded?) throws -> [String: Any] {
        let data = try #require(request?.body?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func filters(_ body: [String: Any]) -> [String: [String: Any]] {
        let list = (body["filters"] as? [[String: Any]]) ?? []
        return Dictionary(list.map { (($0["field"] as? String) ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static let metrics = #""impressions":100,"taps":10,"tapInstalls":2,"viewInstalls":1,"totalInstalls":3,"localSpend":{"amount":"5.00","currency":"USD"}"#

    @Test("campaignInfos maps the app and the daily budget")
    func campaignInfosMapsAppAndBudget() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":[{"id":1,"name":"C","displayStatus":"RUNNING","promotedObjectId":"99","dailyBudget":{"value":{"amount":"12.50","currency":"USD"}},"targeting":{"countryOrRegion":{"include":["us"]}}}],"pagination":{"offset":0,"pageSize":1,"totalCount":1}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let infos = try await client.campaignInfos()
        #expect(infos == [AppleAdsCampaignInfo(id: 1, appStoreId: 99, name: "C", status: "RUNNING", countries: ["US"], dailyBudget: 12.5, currency: "USD")])
        await session.shutdown()
    }

    @Test("keywords pages through the keyword query for one campaign")
    func keywordsPaginates() async throws {
        let page1 = (1...1000).map { #"{"id":\#($0),"campaignId":7,"adGroupId":8,"text":"k\#($0)","matchType":"EXACT","status":"ACTIVE","bid":{"amount":"1.00","currency":"USD"}}"# }
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":[\#(page1.joined(separator: ","))],"pagination":{"offset":0,"pageSize":1000,"totalCount":1001}}"#),
            .init(status: .ok, json: #"{"result":[{"id":1001,"campaignId":7,"adGroupId":8,"text":"last","matchType":"BROAD","status":"PAUSED"}],"pagination":{"offset":1000,"pageSize":1,"totalCount":1001}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let keywords = try await client.keywords(campaignId: 7)
        #expect(keywords.count == 1001)
        #expect(keywords.first?.bid == 1.0)
        #expect(keywords.last == AppleAdsKeywordInfo(id: 1001, campaignId: 7, adGroupId: 8, text: "last", matchType: "BROAD", status: "PAUSED", bid: nil, currency: nil))
        let filter = Self.filters(try Self.body(await transport.requests.first))["campaignId"]
        #expect((filter?["value"] as? NSNumber)?.int64Value == 7)
        await session.shutdown()
    }

    @Test("campaignDays turns each dated granular row into a day")
    func campaignDaysExplodesGranularRows() async throws {
        let granular = ["2026-10-01", "2026-10-02", "2026-10-03"].map { #"{"date":"\#($0)",\#(Self.metrics)}"# }
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"rows":[{"metadata":{"id":1,"name":"C"},"granularMetrics":[\#(granular.joined(separator: ","))]}]},"pagination":{"offset":0,"pageSize":1,"totalCount":1}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let days = try await client.campaignDays(campaignIds: [1], from: "2026-10-01", to: "2026-10-03")
        #expect(days.map(\.date) == ["2026-10-01", "2026-10-02", "2026-10-03"])
        #expect(days.first == AppleAdsCampaignDay(
            campaignId: 1, date: "2026-10-01",
            metrics: AppleAdsMetrics(impressions: 100, taps: 10, tapInstalls: 2, viewInstalls: 1, totalInstalls: 3, spend: 5),
            currency: "USD"
        ))
        let range = try #require(try Self.body(await transport.requests.first)["timeRange"] as? [String: Any])
        #expect(range["timeZone"] as? String == "ORTZ")
        #expect(range["granularity"] as? String == "DAILY")
        await session.shutdown()
    }

    @Test("keywordDays carries country and Apple's suggested bid, grouped by country")
    func keywordDaysCarriesCountryAndSuggestedBid() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"rows":[{"metadata":{"id":5,"campaignId":1,"text":"flashcards","countryOrRegion":"us"},"insights":{"bidRecommendation":{"suggestedBidAmount":1.75}},"granularMetrics":[{"date":"2026-10-01",\#(Self.metrics)}]}]}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let days = try await client.keywordDays(campaignId: 1, from: "2026-10-01", to: "2026-10-01")
        #expect(days == [AppleAdsKeywordDay(
            keywordId: 5, campaignId: 1, country: "US", date: "2026-10-01",
            metrics: AppleAdsMetrics(impressions: 100, taps: 10, tapInstalls: 2, viewInstalls: 1, totalInstalls: 3, spend: 5),
            suggestedBid: 1.75
        )])
        let body = try Self.body(await transport.requests.first)
        #expect(body["groupBy"] as? [String] == ["countryOrRegion"])
        #expect((body["timeRange"] as? [String: Any])?["timeZone"] as? String == "ORTZ")
        #expect((Self.filters(body)["campaignId"]?["value"] as? NSNumber)?.int64Value == 1)
        await session.shutdown()
    }

    @Test("searchTermDays maps a missing term to LOW_VOLUME")
    func searchTermDaysNullTermIsLowVolume() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"rows":[{"metadata":{"campaignId":1,"adGroupId":2,"searchTermSource":"AUTO","countryOrRegion":"US"},"granularMetrics":[{"date":"2026-10-01",\#(Self.metrics)}]},{"metadata":{"campaignId":1,"adGroupId":2,"searchTermText":"flash cards","searchTermSource":"TARGETED","countryOrRegion":"US","keyword":{"id":5}},"granularMetrics":[{"date":"2026-10-01",\#(Self.metrics)}]}]}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let days = try await client.searchTermDays(campaignId: 1, from: "2026-10-01", to: "2026-10-01")
        #expect(days.map(\.term) == ["LOW_VOLUME", "flash cards"])
        #expect(days.map(\.keywordId) == [nil, 5])
        #expect(days.allSatisfy { $0.country == "US" && $0.adGroupId == 2 })
        await session.shutdown()
    }

    @Test("popularity batches 100 terms per request and filters term, country and genre")
    func popularityBatchesAndFilters() async throws {
        let row = #"{"result":{"rows":[{"week":"2026-10-11","countryOrRegion":"US","genre":"EDUCATION","searchTerm":"Term1","searchPopularity1to100":55,"searchPopularity1to5":3,"rankInGenre":12}]}}"#
        let transport = StubAppleAdsTransport([.init(status: .ok, json: row), .init(status: .ok, json: #"{"result":{"rows":[]}}"#)])
        let (client, session) = Self.makeClient(transport)
        let terms = (1...150).map { "term\($0)" }
        let result = try await client.termPopularity(terms: terms, country: "us", genre: "EDUCATION")
        #expect(result == [AppleAdsTermPopularity(term: "term1", country: "US", genre: "EDUCATION", week: "2026-10-11", popularity100: 55, popularity5: 3, rankInGenre: 12)])
        let requests = await transport.requests
        #expect(requests.count == 2)
        let filters = Self.filters(try Self.body(requests.first))
        #expect((filters["searchTerm"]?["value"] as? [String])?.count == 100)
        #expect(filters["countryOrRegion"]?["value"] as? String == "US")
        #expect(filters["genre"]?["value"] as? String == "EDUCATION")
        await session.shutdown()
    }

    @Test("keywordIdeas asks for the app's suggestions in one country")
    func keywordIdeasSendsAppAndCountry() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":[{"text":"anki","popularity":40},{"text":"study cards"}]}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        let ideas = try await client.keywordIdeas(appStoreId: 99, country: "us")
        #expect(ideas == [
            AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "anki", popularity: 40),
            AppleAdsKeywordIdea(appStoreId: 99, country: "US", text: "study cards", popularity: nil),
        ])
        let list = (try Self.body(await transport.requests.first)["filters"] as? [[String: Any]]) ?? []
        let byField = Dictionary(list.map { (($0["field"] as? String) ?? "", $0["value"] as? [String] ?? []) }, uniquingKeysWith: { a, _ in a })
        #expect(byField["promotedObjectId"] == ["99"])
        #expect(byField["promotedObjectType"] == ["APPSTORE_APP"])
        #expect(byField["countriesOrRegions"] == ["US"])
        await session.shutdown()
    }

    @Test("genres Apple doesn't rank map to nil; known ones map to Apple's names")
    func unknownGenreIsNil() {
        #expect(AppleAdsGenre.forITunesGenreId(6017) == "EDUCATION")
        #expect(AppleAdsGenre.forITunesGenreId(7001) == "GAMES")       // game subgenre
        #expect(AppleAdsGenre.forITunesGenreId(6007) == "PRODUCTIVITY_UTILITIES")
        #expect(AppleAdsGenre.forITunesGenreId(6011) == nil)          // Music: not in Apple's list
        #expect(AppleAdsGenre.forITunesGenreId(nil) == nil)
    }
}
