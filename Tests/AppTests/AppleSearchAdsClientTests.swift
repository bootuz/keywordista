@testable import App
import Foundation
import Logging
import Testing
import Vapor

@Suite("AppleSearchAdsClient")
struct AppleSearchAdsClientTests {
    // ── TokenCache ───────────────────────────────────────────────────────

    @Test("TokenCache returns the cached token within the TTL window")
    func tokenCache_reusesWithinTTL() async throws {
        let creds = ASACredentials(clientId: "C", clientSecret: "jwt", orgId: nil)
        let cache = ASATokenCache()

        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "tok-1", expiresIn: 3600),
        ])
        let t1 = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))
        #expect(t1 == "tok-1")
        let calls1 = await http.recordedCalls()
        #expect(calls1.count == 1, "first call should hit OAuth once")

        let t2 = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))
        #expect(t2 == "tok-1")
        let calls2 = await http.recordedCalls()
        #expect(calls2.count == 1, "second call within TTL must not re-exchange")
    }

    @Test("TokenCache.invalidate forces re-exchange on next access")
    func tokenCache_invalidateForcesReexchange() async throws {
        let creds = ASACredentials(clientId: "C", clientSecret: "jwt", orgId: nil)
        let cache = ASATokenCache()
        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "tok-1", expiresIn: 3600),
            .oauth(accessToken: "tok-2", expiresIn: 3600),
        ])

        _ = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))
        await cache.invalidate(clientId: "C")
        let t2 = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))
        #expect(t2 == "tok-2")
        let calls = await http.recordedCalls()
        #expect(calls.count == 2)
    }

    @Test("OAuth request encodes all params on the URL query with an empty body")
    func tokenCache_oauthRequestShape() async throws {
        let creds = ASACredentials(
            clientId: "SEARCHADS.abc-123",
            clientSecret: "eyJ.jwt.value",
            orgId: "999"
        )
        let cache = ASATokenCache()
        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "tok", expiresIn: 3600),
        ])

        _ = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))

        let recorded = await http.recordedCalls()
        #expect(recorded.count == 1)
        let oauth = recorded[0]
        #expect(oauth.method == .POST)
        #expect(oauth.url.hasPrefix("https://appleid.apple.com/auth/oauth2/token?"))
        #expect(oauth.url.contains("grant_type=client_credentials"))
        // `percent(_:)` keeps RFC 3986 unreserved chars (`-._~`) literal.
        #expect(oauth.url.contains("client_id=SEARCHADS.abc-123"))
        #expect(oauth.url.contains("client_secret=eyJ.jwt.value"))
        #expect(oauth.url.contains("scope=searchadsorg"))
        // X-AP-Context belongs only on data calls, not on the OAuth exchange.
        #expect(oauth.headers.first(name: "X-AP-Context") == nil)
        #expect(oauth.headers.first(name: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("TokenCache surfaces OAuth failure as Failure.oauthFailed")
    func tokenCache_oauthFailureSurfaces() async throws {
        let creds = ASACredentials(clientId: "C", clientSecret: "bad", orgId: nil)
        let cache = ASATokenCache()
        let http = ScriptableHTTPClient(scripts: [
            .oauthError(status: .unauthorized, body: "{\"error\":\"invalid_client\"}"),
        ])

        await #expect(throws: AppleSearchAdsClient.Failure.self) {
            _ = try await cache.token(credentials: creds, http: http, logger: Logger(label: "t"))
        }
    }

    // ── Search-terms decoder ────────────────────────────────────────────

    @Test("decode parses the search-terms reporting envelope and skips the rollup row")
    func decoder_parsesEnvelope() async throws {
        let json = #"""
        {
          "data": {
            "row": [
              {
                "other": true,
                "total": { "impressions": 999, "taps": 100 },
                "metadata": {}
              },
              {
                "other": false,
                "total": { "impressions": 312, "taps": 48, "ttr": 0.15, "localSpend": { "amount": "7.50", "currency": "USD" } },
                "metadata": { "searchTermText": "neet flashcards", "searchTermSource": "AUTO" }
              },
              {
                "other": false,
                "total": { "impressions": 89, "taps": 12, "ttr": 0.135 },
                "metadata": { "searchTermText": "anki for medical", "searchTermSource": "AUTO" }
              }
            ]
          }
        }
        """#

        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "t", expiresIn: 3600),
            .json(status: .ok, body: json),
        ])
        let cache = ASATokenCache()
        let asa = AppleSearchAdsClient(
            credentials: .init(clientId: "C", clientSecret: "j", orgId: nil),
            tokenCache: cache,
            http: http,
            logger: Logger(label: "t")
        )

        let results = try await asa.searchTermsReport(
            campaignId: 1,
            startDate: Date(),
            endDate: Date()
        )

        #expect(results.count == 2, "the 'other' rollup row must be excluded")
        #expect(results[0].text == "neet flashcards")
        #expect(results[0].impressions == 312)
        #expect(results[0].taps == 48)
        #expect(abs(results[0].ttr - 0.15) < 1e-6)
        #expect(abs(results[0].localSpend - 7.50) < 1e-6)
        #expect(results[1].text == "anki for medical")
        // localSpend missing → 0 fallback
        #expect(results[1].localSpend == 0)
    }

    // ── X-AP-Context header ─────────────────────────────────────────────

    @Test("X-AP-Context header is sent when orgId is configured")
    func headers_includesOrgContextWhenPresent() async throws {
        let creds = ASACredentials(clientId: "C", clientSecret: "j", orgId: "999")
        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "t", expiresIn: 3600),
            .json(status: .ok, body: #"{ "data": [] }"#),
        ])
        let asa = AppleSearchAdsClient(
            credentials: creds,
            tokenCache: ASATokenCache(),
            http: http,
            logger: Logger(label: "t")
        )
        _ = try await asa.listCampaigns()
        let recorded = await http.recordedCalls()
        // Second call is the campaigns list. OAuth was first.
        let campaignsCall = recorded[1]
        #expect(campaignsCall.headers.first(name: "X-AP-Context") == "orgId=999")
    }

    @Test("X-AP-Context header is omitted when orgId is nil/empty")
    func headers_omitsOrgContextWhenAbsent() async throws {
        let creds = ASACredentials(clientId: "C", clientSecret: "j", orgId: nil)
        let http = ScriptableHTTPClient(scripts: [
            .oauth(accessToken: "t", expiresIn: 3600),
            .json(status: .ok, body: #"{ "data": [] }"#),
        ])
        let asa = AppleSearchAdsClient(
            credentials: creds,
            tokenCache: ASATokenCache(),
            http: http,
            logger: Logger(label: "t")
        )
        _ = try await asa.listCampaigns()
        let recorded = await http.recordedCalls()
        let campaignsCall = recorded[1]
        #expect(campaignsCall.headers.first(name: "X-AP-Context") == nil)
    }
}

// ── Test helpers ─────────────────────────────────────────────────────────

/// Tiny `ASAHTTPClient` stub. Each call pops the next scripted response from
/// a queue; calls are recorded for assertion.
actor ScriptableHTTPClient: ASAHTTPClient {
    enum Script {
        case oauth(accessToken: String, expiresIn: Int)
        case oauthError(status: HTTPResponseStatus, body: String)
        case json(status: HTTPResponseStatus, body: String)
    }
    struct RecordedCall {
        let method: HTTPMethod
        let url: String
        let headers: HTTPHeaders
    }

    private var scripts: [Script]
    private var calls: [RecordedCall] = []

    init(scripts: [Script]) { self.scripts = scripts }

    func recordedCalls() -> [RecordedCall] { calls }

    func get(url: String, headers: HTTPHeaders) async throws -> ClientResponse {
        calls.append(RecordedCall(method: .GET, url: url, headers: headers))
        return try pop()
    }

    func post(url: String, headers: HTTPHeaders, body: Data) async throws -> ClientResponse {
        calls.append(RecordedCall(method: .POST, url: url, headers: headers))
        return try pop()
    }

    private func pop() throws -> ClientResponse {
        guard !scripts.isEmpty else {
            throw Abort(.internalServerError, reason: "scripted client out of responses")
        }
        let script = scripts.removeFirst()
        let alloc = ByteBufferAllocator()
        switch script {
        case .oauth(let token, let expiresIn):
            let body = #"{"access_token":"\#(token)","expires_in":\#(expiresIn),"token_type":"Bearer"}"#
            return ClientResponse(status: .ok, headers: [:], body: alloc.buffer(string: body))
        case .oauthError(let status, let body):
            return ClientResponse(status: status, headers: [:], body: alloc.buffer(string: body))
        case .json(let status, let body):
            return ClientResponse(status: status, headers: [:], body: alloc.buffer(string: body))
        }
    }
}
