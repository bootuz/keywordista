@testable import App
import AppleAdsClient
import Foundation
import HTTPTypes
import Logging
import OpenAPIRuntime
import Testing
import Vapor

@Suite("AppleAdsPlatformClient (Platform API v1)")
struct AppleAdsPlatformClientTests {

    // ── Fixtures ───────────────────────────────────────────────────────

    private static func creds(adAccountId: String? = "42", orgId: String? = nil) -> ASACredentials {
        ASACredentials(clientId: "SEARCHADS.t", clientSecret: "jwt", orgId: orgId, adAccountId: adAccountId)
    }

    /// Client wired to `transport`, with the production middleware but no real sleeping.
    private static func makeClient(
        _ transport: StubAppleAdsTransport,
        creds: ASACredentials = creds()
    ) -> (AppleAdsPlatformClient, AppleAdsSession) {
        let session = AppleAdsSession(logger: Logger(label: "t")) { _ in
            try await makeTestAppleAdsClient(
                transport: transport,
                middleware: AppleAdsSession.standardMiddleware(retrySleep: { _ in })
            )
        }
        return (AppleAdsPlatformClient(credentials: creds, session: session, logger: Logger(label: "t")), session)
    }

    private static func campaign(_ id: Int, countries: [String]) -> String {
        let list = countries.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"id":\#(id),"name":"C\#(id)","displayStatus":"RUNNING","targeting":{"countryOrRegion":{"include":[\#(list)]}}}"#
    }

    private static func campaignPage(_ items: [String], offset: Int, total: Int) -> StubAppleAdsTransport.Canned {
        .init(status: .ok, json: #"{"result":[\#(items.joined(separator: ","))],"pagination":{"offset":\#(offset),"pageSize":\#(items.count),"totalCount":\#(total)}}"#)
    }

    private static func json(_ body: String?) throws -> [String: Any] {
        let data = try #require(body?.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // ── Campaigns ──────────────────────────────────────────────────────

    @Test("campaign query pages until totalCount and uppercases countries")
    func campaignQueryPaginatesAndMapsCountries() async throws {
        let first = (1...1000).map { Self.campaign($0, countries: ["us"]) }
        let transport = StubAppleAdsTransport([
            Self.campaignPage(first, offset: 0, total: 1001),
            Self.campaignPage([Self.campaign(1001, countries: ["gb", "de"])], offset: 1000, total: 1001),
        ])
        let (client, session) = Self.makeClient(transport)
        let campaigns = try await client.campaignInfos()
        #expect(campaigns.count == 1001)
        #expect(campaigns.first?.countries == ["US"])
        #expect(campaigns.last?.id == 1001)
        #expect(campaigns.last?.countries == ["GB", "DE"])
        #expect(campaigns.last?.status == "RUNNING")
        #expect(await transport.requests.count == 2)
        await session.shutdown()
    }

    @Test("campaign query sends the ad-account context header and APPSTORE_APP filter")
    func campaignQuerySendsAdAccountContextHeader() async throws {
        let transport = StubAppleAdsTransport([Self.campaignPage([], offset: 0, total: 0)])
        let (client, session) = Self.makeClient(transport)
        _ = try await client.campaignInfos()
        let request = try #require(await transport.requests.first)
        #expect(request.path.hasSuffix("/campaigns/query"))
        #expect(request.headers[HTTPField.Name("X-AP-Context")!] == XApContext(adAccountID: 42).rawValue)
        let filters = try #require(Self.json(request.body)["filters"] as? [[String: Any]])
        #expect(filters.first?["field"] as? String == "promotedObjectType")
        #expect(filters.first?["value"] as? String == "APPSTORE_APP")
        await session.shutdown()
    }

    @Test("campaign IDs sent as strings still decode")
    func campaignStringIdsDecode() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":[{"id":"77","name":"S","targeting":{"countryOrRegion":{"include":["US"]}}}],"pagination":{"offset":0,"pageSize":1,"totalCount":1}}"#),
        ])
        let (client, session) = Self.makeClient(transport)
        #expect(try await client.campaignInfos().first?.id == 77)
        await session.shutdown()
    }

    // ── Ad-account resolution ──────────────────────────────────────────

    private static func acls(_ accounts: [(id: Int, org: Int)]) -> StubAppleAdsTransport.Canned {
        let items = accounts.map { #"{"adAccount":{"id":\#($0.id),"name":"A\#($0.id)","orgId":\#($0.org)},"roles":["Admin"]}"# }
        return .init(status: .ok, json: #"{"result":{"acls":[\#(items.joined(separator: ","))]}}"#)
    }

    @Test("a single accessible ad account is used automatically")
    func resolvesSingleAccount() async throws {
        let transport = StubAppleAdsTransport([Self.acls([(5, 1)])])
        let (client, session) = Self.makeClient(transport, creds: Self.creds(adAccountId: nil))
        #expect(try await client.resolveAdAccountId() == 5)
        #expect(await transport.requests.first?.headers[HTTPField.Name("X-AP-Context")!] == nil)
        await session.shutdown()
    }

    @Test("the account matching the stored v5 org ID wins")
    func resolvesAccountByLegacyOrgId() async throws {
        let transport = StubAppleAdsTransport([Self.acls([(5, 1), (6, 2)])])
        let (client, session) = Self.makeClient(transport, creds: Self.creds(adAccountId: nil, orgId: "2"))
        #expect(try await client.resolveAdAccountId() == 6)
        await session.shutdown()
    }

    @Test("ambiguous accounts ask the user to choose instead of guessing")
    func resolvesAmbiguousAccountsAsSelectionRequired() async throws {
        let transport = StubAppleAdsTransport([Self.acls([(5, 1), (6, 1)])])
        let (client, session) = Self.makeClient(transport, creds: Self.creds(adAccountId: nil, orgId: "1"))
        await #expect {
            _ = try await client.resolveAdAccountId()
        } throws: { error in
            guard case .adAccountSelectionRequired(let accounts) = error as? AppleAdsError else { return false }
            return accounts.map(\.id) == ["5", "6"]
        }
        await session.shutdown()
    }

    @Test("a stored ad account ID skips the ACL lookup")
    func explicitAdAccountIdSkipsAcls() async throws {
        let transport = StubAppleAdsTransport([Self.campaignPage([], offset: 0, total: 0)])
        let (client, session) = Self.makeClient(transport)
        _ = try await client.campaignInfos()
        #expect(await transport.requests.map(\.operationID) == [Operations.PostCampaignsQuery.id])
        await session.shutdown()
    }

    // ── Errors and retries ─────────────────────────────────────────────

    @Test("429 on a query is retried, then succeeds")
    func retriesQueryOn429ThenSucceeds() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .tooManyRequests, json: "{}", headers: [HTTPField.Name("Retry-After")!: "0"]),
            Self.campaignPage([Self.campaign(1, countries: ["US"])], offset: 0, total: 1),
        ])
        let (client, session) = Self.makeClient(transport)
        #expect(try await client.campaignInfos().count == 1)
        #expect(await transport.requests.count == 2)
        await session.shutdown()
    }

    @Test("429 on a PUT is not retried")
    func doesNotRetryPut() async throws {
        let middleware = AppleAdsRetryMiddleware(sleep: { _ in })
        let calls = CallCounter()
        let request = HTTPRequest(method: .put, scheme: "https", authority: "api.ads.apple.com", path: "/v1/campaigns/1")
        let (response, _) = try await middleware.intercept(
            request, body: nil, baseURL: URL(string: "https://api.ads.apple.com/v1")!, operationID: "putCampaignsId"
        ) { _, _, _ in
            await calls.bump()
            return (HTTPResponse(status: .tooManyRequests), HTTPBody?.none)
        }
        #expect(response.status == .tooManyRequests)
        #expect(await calls.count == 1)
    }

    @Test("401 maps to a readable unauthorized error whatever the body")
    func unauthorizedMapsToReadableError() async throws {
        let transport = StubAppleAdsTransport([.init(status: .unauthorized, json: "{}")])
        let (client, session) = Self.makeClient(transport)
        await #expect(throws: AppleAdsError.unauthorized) { _ = try await client.campaignInfos() }
        await session.shutdown()
    }

    @Test("an undecodable response becomes a readable error, not a decoding dump")
    func decodeFailureIsReadable() async throws {
        let transport = StubAppleAdsTransport([
            .init(status: .ok, json: #"{"result":{"acls":[{"adAccount":{"id":"abc","name":"x","orgId":1}}]}}"#),
        ])
        let (client, session) = Self.makeClient(transport, creds: Self.creds(adAccountId: nil))
        await #expect {
            _ = try await client.listAdAccounts()
        } throws: { error in
            guard case .unreadableResponse = error as? AppleAdsError else { return false }
            return (error as? AppleAdsError)?.description.contains("couldn't read") == true
        }
        await session.shutdown()
    }
}

extension AppleAdsPlatformClientTests {
    @Test("every Apple Ads error reaches any route as a 502 with its copy, never a 500 or 401")
    func appleAdsErrorsAreBadGateway() {
        let error: any AbortError = AppleAdsError.adAccountSelectionRequired([])
        #expect(error.status == .badGateway)
        #expect(error.reason == AppleAdsError.adAccountSelectionRequired([]).description)
        #expect((AppleAdsError.unauthorized as any AbortError).status == .badGateway)
    }
}

private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}
